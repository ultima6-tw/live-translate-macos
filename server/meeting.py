import re
import sys
import json
import os
import time
import atexit
import subprocess
import threading
import queue
import opencc
import numpy as np
import sounddevice as sd
from scipy.signal import resample_poly
from collections import deque
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.text import Text
from rich.console import Console

_s2twp = opencc.OpenCC("s2twp")

_cfg = json.load(open("config.json"))
_use_loopback = "-l" in sys.argv or "--loopback" in sys.argv

_device_name: str = ""
if "--device" in sys.argv:
    _idx = sys.argv.index("--device")
    if _idx + 1 < len(sys.argv):
        _device_name = sys.argv[_idx + 1]
elif _use_loopback:
    _device_name = _cfg.get("loopback_device", "Loopback Audio")
else:
    _device_name = _cfg.get("device", "")

# --pair en-zh or --pair ja-zh → dual-ASR auto-detect mode
# --lang en/ja/zh              → single-language mode (legacy)
_PAIR: list[str] | None = None
LANGUAGE = "en"

if "--pair" in sys.argv:
    _idx = sys.argv.index("--pair")
    if _idx + 1 < len(sys.argv):
        _PAIR = sys.argv[_idx + 1].split("-")
        LANGUAGE = _PAIR[0]
elif "--lang" in sys.argv:
    _idx = sys.argv.index("--lang")
    if _idx + 1 < len(sys.argv):
        LANGUAGE = sys.argv[_idx + 1]

_LANG_TO_LOCALE = {"en": "en-US", "ja": "ja-JP", "zh": "zh-TW"}

# Pair mode: 4 panels
p1_lines = deque(maxlen=100)  # EN/JA 原文
p2_lines = deque(maxlen=100)  # EN/JA → ZH 翻譯
p3_lines = deque(maxlen=100)  # ZH 原文
p4_lines = deque(maxlen=100)  # ZH → EN/JA 翻譯

display_lock = threading.Lock()
_partial_state = {"p1": False, "p3": False}  # 只有原文 panel 有 partial

layout = Layout()
if _PAIR:
    layout.split_column(
        Layout(name="p1", ratio=1),
        Layout(name="p2", ratio=1),
        Layout(name="p3", ratio=1),
        Layout(name="p4", ratio=1),
    )
else:
    layout.split_column(Layout(name="p1", ratio=1), Layout(name="p3", ratio=1))

_TARGET_RE = re.compile(r'[^\x20-\xFF　-鿿豈-﫿]')
_CJK_RE    = re.compile(r'[一-鿿]')   # CJK 統一表意文字（漢字）
_KANA_RE   = re.compile(r'[぀-ヿ]')   # 平假名 + 片假名

_dbg = open("/tmp/jasub_debug.log", "w", buffering=1)


def _log(msg: str):
    _dbg.write(f"{time.strftime('%H:%M:%S')} {msg}\n")


_log(f"argv: {sys.argv}")
_log(f"PAIR={_PAIR} LANGUAGE={LANGUAGE}")


def _detect_lang(text: str) -> str:
    """偵測文字語言：ja（含假名）/ zh（漢字為主）/ en（其他）"""
    s = text.replace(' ', '')
    if not s:
        return "en"
    total = len(s)
    if len(_KANA_RE.findall(s)) / total > 0.08:
        return "ja"
    if len(_CJK_RE.findall(s)) / total > 0.15:
        return "zh"
    return "en"


def _lines_for(panel: str) -> deque:
    return {"p1": p1_lines, "p2": p2_lines, "p3": p3_lines, "p4": p4_lines}[panel]


def is_hallucination(text: str) -> bool:
    if not text:
        return False
    non_target = _TARGET_RE.sub('', text)
    if len(text) - len(non_target) > len(text) * 0.3:
        return True
    for n in range(2, 8):
        prefix = text[:n]
        if text.count(prefix) >= max(5, len(text) // n // 2):
            return True
    words = text.split()
    if len(words) >= 3:
        for size in (1, max(1, len(words) // 3)):
            phrase = " ".join(words[:size])
            if text.count(phrase) >= 3:
                return True
    return False


def _render_lines(d: deque, n: int, margin: int = 2) -> str:
    lines = list(d)
    if len(lines) >= n - 1:
        show = lines[-(n - margin):] if n > margin else lines[-1:]
        return "\n".join(show) + "\n" * margin
    return "\n".join(lines[-n:])


def render(live):
    if _PAIR:
        n = max(2, console.size.height // 4 - 2)
        foreign_label = {"en": "English", "ja": "日本語"}.get(_PAIR[0], _PAIR[0].upper())
        with display_lock:
            c1 = _render_lines(p1_lines, n)
            c2 = _render_lines(p2_lines, n)
            c3 = _render_lines(p3_lines, n)
            c4 = _render_lines(p4_lines, n)
        layout["p1"].update(Panel(Text(c1, style="white"),
                                  title=f"[cyan]{foreign_label}[/cyan]", border_style="cyan"))
        layout["p2"].update(Panel(Text(c2, style="green"),
                                  title="[green]→ 中文[/green]", border_style="green"))
        layout["p3"].update(Panel(Text(c3, style="bold yellow"),
                                  title="[yellow]中文[/yellow]", border_style="yellow"))
        layout["p4"].update(Panel(Text(c4, style="cyan"),
                                  title=f"[cyan]→ {foreign_label}[/cyan]", border_style="cyan"))
    else:
        n = max(3, console.size.height // 2 - 2)
        with display_lock:
            c1 = _render_lines(p1_lines, n)
            c3 = _render_lines(p3_lines, n)
        top_title = "[cyan]English / Japanese[/cyan]" if LANGUAGE in ("en", "ja") else "[cyan]中文[/cyan]"
        bot_title = "[yellow]中文[/yellow]" if LANGUAGE in ("en", "ja") else "[yellow]English[/yellow]"
        layout["p1"].update(Panel(Text(c1, style="white"), title=top_title, border_style="cyan"))
        layout["p3"].update(Panel(Text(c3, style="bold yellow"), title=bot_title, border_style="yellow"))
    live.refresh()


_translate_q: queue.Queue = queue.Queue(maxsize=20)
_translator_proc: subprocess.Popen | None = None

def _compile_swift(src: str, out: str, label: str):
    needs = not os.path.exists(out) or os.path.getmtime(src) > os.path.getmtime(out)
    if not needs:
        return
    console.print(f"  [dim]編譯 {label}（首次需要幾秒）...[/dim]")
    r = subprocess.run(["swiftc", "-O", src, "-o", out], capture_output=True, text=True)
    if r.returncode != 0:
        console.print(f"  [red]{label} 編譯失敗：{r.stderr[:300]}[/red]")
        sys.exit(1)
    console.print(f"  [green]{label} 編譯完成[/green]")


def _translator_stderr_reader(proc: subprocess.Popen):
    for line in proc.stderr:
        msg = line.decode("utf-8").strip()
        if msg:
            _log(f"translator stderr: {msg}")


def _start_translator() -> subprocess.Popen:
    d = os.path.dirname(os.path.abspath(__file__))
    _compile_swift(f"{d}/translator.swift", f"{d}/translator", "翻譯器")
    proc = subprocess.Popen([f"{d}/translator"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, bufsize=0)
    threading.Thread(target=_translator_stderr_reader, args=(proc,), daemon=True).start()
    return proc


def _macos_translate(text: str, src: str, tgt: str) -> str:
    if _translator_proc is None or _translator_proc.poll() is not None:
        return ""
    try:
        _translator_proc.stdin.write(f"{src}\t{tgt}\t{text}\n".encode("utf-8"))
        _translator_proc.stdin.flush()
        result = _translator_proc.stdout.readline()
        return result.decode("utf-8").strip() if result else ""
    except Exception as e:
        _log(f"translator error: {e}")
        return ""


def _do_translate(text: str, src_lang: str, live):
    if src_lang in ("en", "ja"):
        src = src_lang
        tgt = "zh-Hant"
        dest_panel = "p2" if _PAIR else "p3"
    else:  # zh
        src = "zh-Hans"
        tgt = _PAIR[0] if _PAIR and _PAIR[1] == "zh" else "en"
        dest_panel = "p4" if _PAIR else "p3"

    _log(f"translate: src={src} tgt={tgt} text={repr(text[:40])}")
    result = _macos_translate(text, src, tgt)
    _log(f"translate result: {repr(result[:40]) if result else 'EMPTY'}")
    if not result:
        return
    if tgt == "zh-Hant":
        result = _s2twp.convert(result)

    with display_lock:
        _lines_for(dest_panel).append(result)
    render(live)


def _translation_worker():
    while True:
        text, detected_lang, live = _translate_q.get()
        _do_translate(text, detected_lang, live)


# --- Audio capture ---

_audio_chunk_q: queue.Queue = queue.Queue(maxsize=200)
_native_rate: int = 44100


def _find_device_idx(device_name: str) -> int | None:
    for i, d in enumerate(sd.query_devices()):
        if d['name'] == device_name and d['max_input_channels'] > 0:
            return i
    return None


def _start_sounddevice() -> sd.InputStream:
    global _native_rate
    device_idx = _find_device_idx(_device_name) if _device_name else None

    if _device_name and device_idx is None:
        console.print(f"  [yellow]Warning: audio device '{_device_name}' not found, using default[/yellow]")

    info = sd.query_devices(device_idx if device_idx is not None else sd.default.device[0])
    _native_rate = int(info['default_samplerate'])
    console.print(f"  audio : [cyan]{info['name']}[/cyan]  {_native_rate}Hz")

    _cb_count = [0]
    def _cb(indata, frames, _time, status):
        _cb_count[0] += 1
        if _cb_count[0] == 1 or _cb_count[0] % 100 == 0:
            _log(f"sounddevice cb #{_cb_count[0]} frames={frames}")
        mono = indata[:, 0].copy().astype(np.float32)
        try:
            _audio_chunk_q.put_nowait(mono)
        except queue.Full:
            pass

    stream = sd.InputStream(
        samplerate=_native_rate,
        channels=1,
        dtype='float32',
        device=device_idx,
        blocksize=4096,
        callback=_cb,
    )
    stream.start()
    return stream


def _audio_writer():
    """Resample to 16kHz and pipe float32 PCM to all ASR process(es)."""
    from_rate = _native_rate
    to_rate = 16000
    count = 0
    _log(f"audio_writer started from_rate={from_rate}")
    while True:
        chunk = _audio_chunk_q.get()
        count += 1
        if count == 1 or count % 100 == 0:
            _log(f"audio_writer chunk #{count}")
        if from_rate != to_rate:
            chunk = resample_poly(chunk, to_rate, from_rate).astype(np.float32)
        pcm = chunk.tobytes()
        for proc in _asr_procs.values():
            try:
                proc.stdin.write(pcm)
                proc.stdin.flush()
            except Exception as e:
                _log(f"audio_writer write error: {e}")


def _start_asr_proc(lang: str) -> subprocess.Popen:
    d = os.path.dirname(os.path.abspath(__file__))
    _compile_swift(f"{d}/asr.swift", f"{d}/asr", "ASR")

    locale = _LANG_TO_LOCALE.get(lang, lang)
    cmd = [f"{d}/asr", "--lang", locale]
    console.print(f"  locale : [cyan]{locale}[/cyan]")
    console.print("  [yellow]若出現「語音辨識」授權請求，請點選「允許」[/yellow]")

    proc = subprocess.Popen(cmd,
                            stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            bufsize=0)
    time.sleep(0.5)
    if proc.poll() is not None:
        err = proc.stderr.read().decode()
        console.print(f"  [red]ASR 啟動失敗（{lang}）：{err[:200]}[/red]")
        sys.exit(1)
    return proc


# --- Merged ASR output queue ---
_asr_output_q: queue.Queue = queue.Queue()


def _asr_reader_thread(proc: subprocess.Popen, lang_hint: str):
    for raw in proc.stdout:
        _asr_output_q.put((raw, lang_hint))


def _asr_stderr_thread(proc: subprocess.Popen, lang_hint: str):
    for line in proc.stderr:
        msg = line.decode("utf-8").strip()
        if msg:
            _log(f"ASR({lang_hint}) stderr: {msg}")


# --- Startup ---

console = Console()

console.print("[cyan]啟動 macOS 翻譯器...[/cyan]")
_translator_proc = _start_translator()
atexit.register(_translator_proc.terminate)
console.print("[green]翻譯器就緒[/green]")

console.print("[cyan]啟動 ASR...[/cyan]")
_asr_procs: dict[str, subprocess.Popen] = {}
langs_to_start = _PAIR if _PAIR else [LANGUAGE]
for _lang in langs_to_start:
    console.print(f"  [dim]啟動 {_lang.upper()} ASR...[/dim]")
    _asr_procs[_lang] = _start_asr_proc(_lang)
    atexit.register(_asr_procs[_lang].terminate)
console.print("[green]ASR 就緒[/green]")

console.print("[cyan]啟動音訊擷取...[/cyan]")
_audio_stream = _start_sounddevice()
atexit.register(_audio_stream.stop)
console.print("[green]音訊擷取就緒[/green]")

threading.Thread(target=_translation_worker, daemon=True).start()
threading.Thread(target=_audio_writer, daemon=True).start()

for _lang, _proc in _asr_procs.items():
    threading.Thread(target=_asr_reader_thread, args=(_proc, _lang), daemon=True).start()
    threading.Thread(target=_asr_stderr_thread, args=(_proc, _lang), daemon=True).start()

_recent_transcriptions = deque(maxlen=5)

# Mutual suppression: track when each ASR last produced a valid final result
_asr_last_final: dict[str, float] = {}
_SUPPRESS_WINDOW = 2.5  # seconds

try:
    with Live(layout, console=console, refresh_per_second=4, screen=True) as live:
        render(live)

        while True:
            try:
                raw, lang_hint = _asr_output_q.get(timeout=0.5)
            except queue.Empty:
                continue

            line = raw.decode("utf-8").strip()
            if not line:
                continue

            is_partial = line.startswith("~")
            text = line[1:] if is_partial else line
            if not text:
                continue

            if _PAIR:
                detected_lang = _detect_lang(text)
                if lang_hint == "en" and detected_lang in ("zh", "ja"):
                    continue
                if lang_hint == "zh" and detected_lang == "ja":
                    continue

                # Mutual suppression: if the other ASR was recently active, suppress this one
                other_lang = _PAIR[1] if lang_hint == _PAIR[0] else _PAIR[0]
                other_last = _asr_last_final.get(other_lang, 0.0)
                elapsed = time.time() - other_last
                if elapsed < _SUPPRESS_WINDOW:
                    _log(f"SUPPRESS {lang_hint} (other={other_lang} active {elapsed:.1f}s ago)")
                    continue

                # p1 = EN/JA 原文，p3 = ZH 原文
                orig_panel = "p3" if lang_hint == "zh" else "p1"
                effective_lang = lang_hint
            else:
                effective_lang = LANGUAGE
                orig_panel = "p1"

            target = _lines_for(orig_panel)

            if is_partial:
                if is_hallucination(text):
                    continue
                with display_lock:
                    if _partial_state[orig_panel] and target:
                        target[-1] = text
                    else:
                        target.append(text)
                        _partial_state[orig_panel] = True
                render(live)
                continue

            # --- final result ---
            _log(f"ASR({lang_hint}→{effective_lang}): {repr(text[:80])}")

            with display_lock:
                if _partial_state[orig_panel] and target:
                    target.pop()
            _partial_state[orig_panel] = False

            if is_hallucination(text):
                _log("  SKIP hallucination")
                render(live)
                continue
            if _recent_transcriptions.count(text) >= 2:
                _log("  SKIP duplicate")
                continue
            _recent_transcriptions.append(text)

            # Update suppression timestamp after accepting this result
            if _PAIR:
                _asr_last_final[lang_hint] = time.time()

            with display_lock:
                target.append(text)
            render(live)

            try:
                _translate_q.put_nowait((text, effective_lang, live))
            except queue.Full:
                pass

except KeyboardInterrupt:
    console.print("\n已停止。")

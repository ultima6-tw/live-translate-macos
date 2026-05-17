import AppKit
import SwiftUI

// MARK: - Panel factory

@MainActor private func makePanel(frame: NSRect) -> NSPanel {
    let panel = NSPanel(
        contentRect: frame,
        styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isMovableByWindowBackground = true
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    // Hide traffic lights
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    return panel
}

// Hosting view with size constraints removed so the window can resize freely
@MainActor private func hostingView<V: View>(_ view: V) -> NSHostingView<V> {
    let hv = NSHostingView(rootView: view)
    hv.sizingOptions = []   // don't lock window to SwiftUI ideal size
    return hv
}

// MARK: - Panel factories used by AppDelegate

@MainActor func makeOriginalPanel(above referenceFrame: NSRect) -> NSPanel {
    let frame = NSRect(
        x: referenceFrame.minX,
        y: referenceFrame.maxY + 8,
        width: referenceFrame.width,
        height: 72
    )
    let panel = makePanel(frame: frame)
    panel.minSize = NSSize(width: 200, height: 44)
    panel.contentView = hostingView(OriginalTextView())
    return panel
}

@MainActor func makeTranslationPanel() -> NSPanel {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let sf = screen.visibleFrame
    let width: CGFloat = min(sf.width * 0.75, 920)
    let height: CGFloat = 120
    let x = sf.minX + (sf.width - width) / 2
    let y = sf.minY + 56
    let panel = makePanel(frame: NSRect(x: x, y: y, width: width, height: height))
    panel.minSize = NSSize(width: 200, height: 50)
    panel.contentView = hostingView(TranslationTextView())
    panel.orderFront(nil)
    return panel
}

// MARK: - SwiftUI: Original text

struct OriginalTextView: View {
    @StateObject private var engine = TranslationEngine.shared

    private var hasContent: Bool { !engine.originalHistory.isEmpty || !engine.originalPartial.isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !hasContent {
                        Text(engine.isRunning ? "聆聽中…" : "原文")
                            .font(.system(size: engine.translationFontSize * 0.7))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    ForEach(Array(engine.originalHistory.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: engine.translationFontSize * 0.7))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !engine.originalPartial.isEmpty {
                        Text(engine.originalPartial)
                            .font(.system(size: engine.translationFontSize * 0.7))
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("partial")
                    } else if !engine.originalHistory.isEmpty {
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 44)
            .onChange(of: engine.originalPartial) { _, _ in
                withAnimation { proxy.scrollTo("partial", anchor: .bottom) }
            }
            .onChange(of: engine.originalHistory.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.black.opacity(0.65))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
        }
        .padding(8)
    }
}

// MARK: - SwiftUI: Translation

struct TranslationTextView: View {
    @StateObject private var engine = TranslationEngine.shared

    private var isIdle: Bool { !engine.isRunning && engine.translatedHistory.isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if isIdle {
                        Text("JaSub · 點選選單列圖示開始")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.35))
                    } else if engine.translatedHistory.isEmpty {
                        Text("翻譯中…")
                            .font(.system(size: engine.translationFontSize, weight: .semibold))
                            .foregroundStyle(.yellow.opacity(0.6))
                    } else {
                        ForEach(Array(engine.translatedHistory.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: engine.translationFontSize, weight: .semibold))
                                .foregroundStyle(idx == engine.translatedHistory.count - 1
                                                 ? .yellow : .yellow.opacity(0.55))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 56)
            .onChange(of: engine.translatedHistory.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(isIdle ? 0.55 : 0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(isIdle ? 0.08 : 0), lineWidth: 1)
                }
        }
        .padding(10)
        .animation(.easeInOut(duration: 0.2), value: isIdle)
    }
}

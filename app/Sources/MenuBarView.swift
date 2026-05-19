import SwiftUI
import AppKit

struct MenuBarView: View {
    @StateObject private var engine = TranslationEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            Label("JaSub", systemImage: "captions.bubble.fill")
                .font(.headline)

            Divider()

            // Source language
            VStack(alignment: .leading, spacing: 4) {
                Text("來源語言").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $engine.selectedSrcID) {
                    ForEach(engine.sourceLanguages) { lang in
                        Text(lang.name).tag(lang.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Target language
            VStack(alignment: .leading, spacing: 4) {
                Text("翻譯目標").font(.caption).foregroundStyle(.secondary)
                if engine.isLoadingTargets {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("載入中…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Picker("", selection: $engine.selectedTgtID) {
                        let installed = engine.targetLanguages.filter(\.isInstalled)
                        let uninstalled = engine.targetLanguages.filter(\.needsDownload)
                        if !installed.isEmpty {
                            Section("已安裝") {
                                ForEach(installed) { lang in
                                    Text(lang.name).tag(lang.id)
                                }
                            }
                        }
                        if !uninstalled.isEmpty {
                            Section("未安裝語言包") {
                                ForEach(uninstalled) { lang in
                                    Text(lang.name + "  ↓").tag(lang.id)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if engine.selectedTgt?.needsDownload == true {
                        Text("前往「系統設定 → 一般 → 語言與地區 → 翻譯語言」安裝語言包")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            // Audio source
            VStack(alignment: .leading, spacing: 4) {
                Text("音源").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $engine.selectedDevice) {
                    Section("輸入裝置") {
                        ForEach(engine.inputDevices) { device in
                            HStack(spacing: 4) {
                                Text(device.name)
                                if device.isDefault {
                                    Text("（預設）").foregroundStyle(.secondary)
                                }
                            }
                            .tag(device.name)
                        }
                    }
                    Section("系統音訊") {
                        Text("瀏覽器 / 系統音訊")
                            .tag(TranslationEngine.systemAudioID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("顯示原文", isOn: $engine.showOriginal)
                .toggleStyle(.checkbox)

            // Font size
            HStack(spacing: 6) {
                Text("字型大小").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(engine.translationFontSize))pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
                Stepper("", value: $engine.translationFontSize, in: 12...40, step: 2)
                    .labelsHidden()
            }

            Divider()

            if let status = engine.startupStatus {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let err = engine.startError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Log status
            if engine.isRunning, let logURL = engine.currentLogURL {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(logURL.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(logURL.deletingLastPathComponent())
                    } label: {
                        Image(systemName: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(engine.isRunning ? "停止" : "開始") {
                    engine.isRunning ? engine.stop() : engine.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isRunning ? .red : .accentColor)
                .disabled(engine.isLoadingTargets || engine.selectedTgtID.isEmpty)
                .keyboardShortcut(.return)

                Spacer()

                Button("記錄資料夾") { openLogsFolder() }
                    .buttonStyle(.bordered)

                Button("結束 JaSub") { NSApp.terminate(nil) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func openLogsFolder() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("JaSub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

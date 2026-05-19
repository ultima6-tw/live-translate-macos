import SwiftUI

@available(iOS 26.0, *)
struct IOSContentView: View {
    @StateObject private var engine = TranslationEngine.shared

    var body: some View {
        VStack(spacing: 0) {
            settingsSection
            Divider()
            subtitleSection
            Divider()
            controlBar
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: Settings

    private var settingsSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Source").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $engine.selectedSrcID) {
                    ForEach(engine.sourceLanguages) { lang in
                        Text(lang.name).tag(lang.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            HStack {
                Text("Target").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if engine.isLoadingTargets {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Picker("", selection: $engine.selectedTgtID) {
                        let installed   = engine.targetLanguages.filter(\.isInstalled)
                        let uninstalled = engine.targetLanguages.filter(\.needsDownload)
                        if !installed.isEmpty {
                            Section("Installed") {
                                ForEach(installed)  { l in Text(l.name).tag(l.id) }
                            }
                        }
                        if !uninstalled.isEmpty {
                            Section("Not installed") {
                                ForEach(uninstalled) { l in Text(l.name + "  ↓").tag(l.id) }
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            Toggle(isOn: $engine.showOriginal) {
                Text("Show Original").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: Subtitle display

    private var subtitleSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if engine.showOriginal {
                        originalBlock
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                        Divider().opacity(0.3)
                    }

                    translationBlock
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                    Color.clear.frame(height: 1).id("bottom")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
            .onChange(of: engine.originalPartial)        { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: engine.translatedHistory.count){ _, _ in withAnimation { proxy.scrollTo("bottom") } }
        }
    }

    // MARK: Original block

    private var originalBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Original")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 2)

            let hasContent = !engine.originalHistory.isEmpty || !engine.originalPartial.isEmpty
            if !hasContent {
                if engine.isRunning {
                    Text("Listening…")
                        .font(.system(size: engine.translationFontSize * 0.7))
                        .foregroundStyle(.white.opacity(0.3))
                } else {
                    Text("Original")
                        .font(.system(size: engine.translationFontSize * 0.7))
                        .foregroundStyle(.white.opacity(0.2))
                }
            }

            ForEach(Array(engine.originalHistory.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: engine.translationFontSize * 0.7))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !engine.originalPartial.isEmpty {
                Text(engine.originalPartial)
                    .font(.system(size: engine.translationFontSize * 0.7))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if engine.isRunning && engine.isASRSilent && !engine.originalHistory.isEmpty {
                Text("⟳ Listening")
                    .font(.system(size: engine.translationFontSize * 0.6))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Translation block

    private var translationBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !engine.isRunning && engine.translatedHistory.isEmpty {
                Text("Tap Start to begin")
                    .font(.system(size: min(engine.translationFontSize, 22)))
                    .foregroundStyle(.white.opacity(0.3))
            } else if engine.translatedHistory.isEmpty {
                Text("Translating…")
                    .font(.system(size: engine.translationFontSize, weight: .semibold))
                    .foregroundStyle(.yellow.opacity(0.6))
            } else {
                ForEach(Array(engine.translatedHistory.enumerated()), id: \.offset) { idx, line in
                    Text(line)
                        .font(.system(size: engine.translationFontSize, weight: .semibold))
                        .foregroundStyle(
                            idx == engine.translatedHistory.count - 1
                                ? .yellow : .yellow.opacity(0.5)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Control bar

    private var controlBar: some View {
        VStack(spacing: 6) {
            if let status = engine.startupStatus {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let err = engine.startError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                // Font size
                HStack(spacing: 4) {
                    Text("\(Int(engine.translationFontSize))pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                    Stepper("", value: $engine.translationFontSize, in: 12...40, step: 2)
                        .labelsHidden()
                }

                Spacer()

                Button(engine.isRunning ? "Stop" : "Start") {
                    engine.isRunning ? engine.stop() : engine.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isRunning ? .red : .accentColor)
                .disabled(engine.isLoadingTargets || engine.selectedTgtID.isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(.regularMaterial)
    }
}

import AVFoundation
import SwiftUI

struct ReaderSettingsView: View {
    @AppStorage("reader.theme") private var themeRaw: String = ReaderTheme.system.rawValue
    @AppStorage("reader.fontFamily") private var fontFamilyRaw: String = ReaderFontFamily.newYork.rawValue
    @AppStorage("reader.width") private var widthRaw: String = ReaderWidth.medium.rawValue
    @AppStorage("reader.mode") private var modeRaw: String = ReadingMode.continuous.rawValue
    @AppStorage("reader.fontSizePt") private var fontSizePt: Double = ReaderMetrics.defaultFontSize
    @AppStorage("reader.lineSpacingPt") private var lineSpacingPt: Double = ReaderMetrics.defaultLineSpacing
    @AppStorage("reader.paragraphSpacingPt") private var paragraphSpacingPt: Double = ReaderMetrics.defaultParagraphSpacing
    @AppStorage("reader.pageTurnHaptics") private var pageTurnHaptics: Bool = false
    @AppStorage(SpeechController.rateKey) private var ttsRate: Double = Double(SpeechController.defaultRate)
    @AppStorage(SpeechController.voiceKey) private var ttsVoiceId: String = ""
    @Environment(\.colorScheme) private var systemColorScheme

    /// On-device voices for the current language (fall back to all installed
    /// voices if the language has none), sorted by name.
    private var voices: [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let matching = all.filter { $0.language.hasPrefix(lang) }
        return (matching.isEmpty ? all : matching).sorted { $0.name < $1.name }
    }

    var body: some View {
        let theme = ReaderTheme(rawValue: themeRaw) ?? .system
        let family = ReaderFontFamily(rawValue: fontFamilyRaw) ?? .newYork
        let scheme = theme.preferredColorScheme ?? systemColorScheme

        Form {
            Section("Preview") {
                VStack(alignment: .leading, spacing: paragraphSpacingPt) {
                    Text("A Coffee Shop Tale")
                        .font(family.font(size: fontSizePt + 6, weight: .bold))
                    Text("Bella poured the latte. It was hot.")
                        .font(family.font(size: fontSizePt))
                        .lineSpacing(lineSpacingPt)
                    Text("Edward looked up from the corner table and met her eyes. The cafe felt suddenly quieter.")
                        .font(family.font(size: fontSizePt))
                        .lineSpacing(lineSpacingPt)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.background(for: scheme))
                .foregroundStyle(theme.foreground(for: scheme))
                .cornerRadius(8)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            Section {
                metricSlider("Text size", value: $fontSizePt, range: ReaderMetrics.fontSizeRange,
                             step: 1, unit: "pt", icon: "textformat.size")
                metricSlider("Line spacing", value: $lineSpacingPt, range: ReaderMetrics.lineSpacingRange,
                             step: 1, unit: "pt", icon: "arrow.up.and.down.text.horizontal")
                metricSlider("Paragraph spacing", value: $paragraphSpacingPt, range: ReaderMetrics.paragraphSpacingRange,
                             step: 2, unit: "pt", icon: "text.justify.left")
            } header: {
                Text("Text size & spacing")
            } footer: {
                Text("Drag the sliders, or tap − / + to fine-tune.")
            }

            Section {
                Picker("Reading mode", selection: $modeRaw) {
                    ForEach(ReadingMode.allCases) { m in
                        Label(m.displayName, systemImage: m.symbol).tag(m.rawValue)
                    }
                }
                .pickerStyle(.inline).labelsHidden()

                Toggle(isOn: $pageTurnHaptics) {
                    Label("Page-turn haptics", systemImage: "hand.tap")
                }
            } header: {
                Text("Reading mode")
            } footer: {
                Text("Continuous scrolls the whole work in one column. Swipe by chapter shows one chapter per page — swipe or tap the left/right edge to turn. Page-turn haptics add a light tap when you turn a page.")
            }

            Section {
                Picker(selection: $ttsVoiceId) {
                    Text("System default").tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                    }
                } label: {
                    Label("Voice", systemImage: "person.wave.2")
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Speaking rate", systemImage: "speedometer").font(.subheadline)
                        Spacer()
                        Text(String(format: "%.1f×", ttsRate / Double(SpeechController.defaultRate)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $ttsRate,
                           in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate))
                }
                .padding(.vertical, 2)
            } header: {
                Text("Spoken audio")
            } footer: {
                Text("Tap the headphones in the reader to have a chapter read aloud — it keeps playing with the screen locked. Voices run entirely on-device; download higher-quality ones in iOS Settings → Accessibility → Spoken Content → Voices.")
            }

            Section("Theme") {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(ReaderTheme.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.inline).labelsHidden()
            }

            Section("Font") {
                Picker("Font", selection: $fontFamilyRaw) {
                    ForEach(ReaderFontFamily.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.inline).labelsHidden()
            }

            Section("Margins") {
                Picker("Margins", selection: $widthRaw) {
                    ForEach(ReaderWidth.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
        }
        .navigationTitle("Reader")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func metricSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                              step: Double, unit: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon).font(.subheadline)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded())) \(unit)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)

                Slider(value: value, in: range, step: step)

                Button {
                    value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack { ReaderSettingsView() }
}

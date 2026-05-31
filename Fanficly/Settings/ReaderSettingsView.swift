import SwiftUI

struct ReaderSettingsView: View {
    @AppStorage("reader.theme") private var themeRaw: String = ReaderTheme.system.rawValue
    @AppStorage("reader.fontSize") private var fontSizeRaw: Int = ReaderFontSize.medium.rawValue
    @AppStorage("reader.fontFamily") private var fontFamilyRaw: String = ReaderFontFamily.newYork.rawValue
    @AppStorage("reader.width") private var widthRaw: String = ReaderWidth.medium.rawValue
    @AppStorage("reader.mode") private var modeRaw: String = ReadingMode.continuous.rawValue
    @AppStorage("reader.lineSpacing") private var lineSpacingRaw: String = ReaderLineSpacing.normal.rawValue
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        let theme = ReaderTheme(rawValue: themeRaw) ?? .system
        let family = ReaderFontFamily(rawValue: fontFamilyRaw) ?? .newYork
        let size = ReaderFontSize(rawValue: fontSizeRaw) ?? .medium
        let spacing = ReaderLineSpacing(rawValue: lineSpacingRaw) ?? .normal
        let scheme = theme.preferredColorScheme ?? systemColorScheme

        Form {
            Section("Preview") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A Coffee Shop Tale")
                        .font(family.font(size: size.cgFloat + 6, weight: .bold))
                    Text("Bella poured the latte. It was hot. Edward looked up from the corner table and met her eyes. The cafe felt suddenly quieter.")
                        .font(family.font(size: size.cgFloat))
                        .lineSpacing(spacing.points)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.background(for: scheme))
                .foregroundStyle(theme.foreground(for: scheme))
                .cornerRadius(8)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            Section {
                Picker("Reading mode", selection: $modeRaw) {
                    ForEach(ReadingMode.allCases) { m in
                        Label(m.displayName, systemImage: m.symbol).tag(m.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Reading mode")
            } footer: {
                Text("Continuous scrolls the whole work in one column. Swipe by chapter shows one chapter per page; flick left/right to advance.")
            }

            Section("Theme") {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(ReaderTheme.allCases) { t in
                        Text(t.displayName).tag(t.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("Font") {
                Picker("Font", selection: $fontFamilyRaw) {
                    ForEach(ReaderFontFamily.allCases) { f in
                        Text(f.displayName).tag(f.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("Font size") {
                Picker("Font size", selection: $fontSizeRaw) {
                    ForEach(ReaderFontSize.allCases) { f in
                        Text(f.displayName).tag(f.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("Line spacing") {
                Picker("Line spacing", selection: $lineSpacingRaw) {
                    ForEach(ReaderLineSpacing.allCases) { s in
                        Text(s.displayName).tag(s.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("Text width") {
                Picker("Text width", selection: $widthRaw) {
                    ForEach(ReaderWidth.allCases) { w in
                        Text(w.displayName).tag(w.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .navigationTitle("Reader")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { ReaderSettingsView() }
}

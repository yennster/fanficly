import SwiftUI

struct ReaderSettingsView: View {
    @AppStorage("reader.theme") private var themeRaw: String = ReaderTheme.system.rawValue
    @AppStorage("reader.fontSize") private var fontSizeRaw: Int = ReaderFontSize.medium.rawValue
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        let theme = ReaderTheme(rawValue: themeRaw) ?? .system
        let scheme = theme.preferredColorScheme ?? systemColorScheme

        Form {
            Section("Preview") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A Coffee Shop Tale")
                        .font(.system(size: CGFloat(fontSizeRaw) + 6, weight: .bold, design: .serif))
                    Text("Bella poured the latte. It was hot. Edward looked up from the corner table and met her eyes. The cafe felt suddenly quieter.")
                        .font(.system(size: CGFloat(fontSizeRaw), design: .serif))
                        .lineSpacing(6)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.background(for: scheme))
                .foregroundStyle(theme.foreground(for: scheme))
                .cornerRadius(8)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
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

            Section("Font size") {
                Picker("Font size", selection: $fontSizeRaw) {
                    ForEach(ReaderFontSize.allCases) { f in
                        Text(f.displayName).tag(f.rawValue)
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

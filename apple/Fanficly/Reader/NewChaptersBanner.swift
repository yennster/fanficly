import SwiftUI

/// AO3 has chapters the downloaded copy doesn't (#180). The Library reader
/// hands this to `ReaderView`, which shows it after the last saved chapter.
struct NewChaptersNotice {
    /// How many chapters AO3 has beyond the saved ones.
    let count: Int
    /// An update is running: the button gives way to a spinner.
    let isUpdating: Bool
    /// Fetches the work once and saves it over the old copy.
    let update: @MainActor () -> Void

    var text: String { DownloadUpdate.bannerText(count: count) }
}

/// The quiet note at the end of the last saved chapter:
/// "3 new chapters on AO3 · Update".
struct NewChaptersBanner: View {
    let notice: NewChaptersNotice
    let foreground: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(foreground.opacity(0.6))
                .accessibilityHidden(true)
            Text(notice.text)
                .font(.callout)
                .foregroundStyle(foreground.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if notice.isUpdating {
                ProgressView()
                    .accessibilityLabel("Updating download")
            } else {
                Button("Update", action: notice.update)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Update download")
                    .accessibilityHint("Saves the new chapters on this device. You stay where you are.")
                    .accessibilityIdentifier("reader.newChapters.update")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.newChapters")
    }
}

import SwiftUI

/// Reader for a work in the Library.
/// - Downloaded works (chapters saved on device) read fully offline.
/// - Bookmarked-only works have no saved chapter text, so we fetch it from
///   AO3 on demand (not persisted — that's what "Save offline" is for).
struct SavedWorkReader: View {
    @Environment(\.ao3Client) private var client
    let work: Work

    @State private var payload: AO3WorkPayload?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var hasOfflineText: Bool { !work.chapters.isEmpty }

    var body: some View {
        Group {
            if hasOfflineText {
                ReaderView(work: work)
            } else if let payload {
                ReaderView(payload: payload)
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading from AO3…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                Color.clear
            }
        }
        .toolbar {
            WorkExportButton(workId: work.ao3Id, title: work.title)
        }
        .task { await load() }
    }

    private func load() async {
        guard !hasOfflineText, payload == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            payload = try await client.fetchWork(id: work.ao3Id)
        } catch {
            errorMessage = "This bookmarked work loads on demand. Connect to the internet to read it, or tap the download button to save it offline."
        }
    }
}

import SwiftUI

/// Reusable export/share toolbar button — downloads the work in the chosen
/// AO3 format and hands it to the iOS share sheet.
struct WorkExportButton: View {
    @Environment(\.ao3Client) private var client
    let workId: Int
    let title: String
    @State private var isExporting = false
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    var body: some View {
        Menu {
            Section("Export & share") {
                ForEach(WorkExportFormat.allCases) { format in
                    Button {
                        Task { await export(format) }
                    } label: {
                        Label(format.displayName, systemImage: format.icon)
                    }
                }
            }
        } label: {
            if isExporting {
                ProgressView()
            } else {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .disabled(isExporting)
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
        .alert("Export failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func export(_ format: WorkExportFormat) async {
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try await client.exportWork(workId: workId, format: format, filename: title)
            shareItem = ShareItem(url: url)
        } catch {
            errorMessage = "Couldn't download the \(format.displayName) file: \(error)"
        }
    }
}

import SwiftUI
import UIKit

/// Drives a work export: downloads the work in the chosen AO3 format and holds
/// the resulting file so the presenting screen can hand it to the share sheet.
///
/// The exporter (and the `.workExportPresentation` modifier that renders its
/// sheet/alert) must be owned by the stable screen view, never by a view inside
/// a `Menu`'s content: menu content is torn down when the menu dismisses, so a
/// `.sheet` attached there has no live anchor by the time the download finishes
/// and silently never presents — VoiceOver users hit this every time (the menu
/// dismisses slower under VoiceOver) and reported "the dialog disappears and
/// nothing happens".
@Observable @MainActor
final class WorkExporter {
    var isExporting = false
    var shareItem: ShareItem?
    var errorMessage: String?

    func export(workId: Int, title: String, format: WorkExportFormat,
                client: any AO3ClientProtocol) async {
        isExporting = true
        defer { isExporting = false }
        // The menu has already dismissed and the download can take several
        // seconds (AO3 throttle), so tell VoiceOver users something is
        // happening; queued so the menu-dismissal speech doesn't clobber it.
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: "Downloading \(format.displayName). The share sheet will open when it's ready.",
            attributes: [.accessibilitySpeechQueueAnnouncement: true]))
        do {
            let url = try await client.exportWork(workId: workId, format: format, filename: title)
            shareItem = ShareItem(url: url)
        } catch {
            errorMessage = "Couldn't download the \(format.displayName) file: \(error)"
        }
    }
}

/// Reusable export/share control — a submenu of AO3 download formats. Embed it
/// in a toolbar or an overflow `Menu`, pass the screen's `WorkExporter`, and
/// attach `.workExportPresentation(exporter)` to the screen itself.
struct WorkExportButton: View {
    @Environment(\.ao3Client) private var client
    let workId: Int
    let title: String
    let exporter: WorkExporter
    var useTextLabel: Bool = false

    var body: some View {
        Menu {
            Section("Export & share") {
                ForEach(WorkExportFormat.allCases) { format in
                    Button {
                        let client = client
                        Task {
                            await exporter.export(workId: workId, title: title,
                                                  format: format, client: client)
                        }
                    } label: {
                        Label(format.displayName, systemImage: format.icon)
                    }
                }
            }
        } label: {
            if exporter.isExporting {
                ProgressView()
            } else {
                if useTextLabel {
                    Label("Share & export...", systemImage: "square.and.arrow.up")
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .disabled(exporter.isExporting)
        .accessibilityLabel("Share and export")
    }
}

private struct WorkExportPresentation: ViewModifier {
    @Bindable var exporter: WorkExporter

    func body(content: Content) -> some View {
        content
            .sheet(item: $exporter.shareItem) { ShareSheet(items: [$0.url]) }
            .alert("Export failed", isPresented: Binding(
                get: { exporter.errorMessage != nil },
                set: { if !$0 { exporter.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exporter.errorMessage ?? "")
            }
    }
}

extension View {
    /// Presents the share sheet / error alert for a `WorkExporter`. Attach to
    /// the screen view that owns the exporter — never inside `Menu` content.
    func workExportPresentation(_ exporter: WorkExporter) -> some View {
        modifier(WorkExportPresentation(exporter: exporter))
    }
}

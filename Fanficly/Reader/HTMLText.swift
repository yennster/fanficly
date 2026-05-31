import SwiftUI

struct HTMLText: View {
    let html: String
    @State private var converted: AttributedString?

    var body: some View {
        Group {
            if let converted {
                Text(converted)
            } else {
                Text(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            }
        }
        .task(id: html) {
            let attr = await Task.detached(priority: .userInitiated) {
                HTMLToAttributed.convert(html)
            }.value
            await MainActor.run { converted = attr }
        }
    }
}

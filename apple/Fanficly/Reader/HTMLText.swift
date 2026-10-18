import SwiftUI

struct HTMLText: View {
    let html: String
    @State private var converted: AttributedString?

    private var fallbackText: String {
        var temp = html
        temp = temp.replacingOccurrences(of: "\r\n", with: "\n")
        // Replace paragraph closures and breaks with newlines
        temp = temp.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        temp = temp.replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: .regularExpression)
        // Strip other HTML tags
        temp = temp.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode common HTML entities
        temp = temp.replacingOccurrences(of: "&amp;", with: "&")
        temp = temp.replacingOccurrences(of: "&lt;", with: "<")
        temp = temp.replacingOccurrences(of: "&gt;", with: ">")
        temp = temp.replacingOccurrences(of: "&quot;", with: "\"")
        temp = temp.replacingOccurrences(of: "&apos;", with: "'")
        temp = temp.replacingOccurrences(of: "&#39;", with: "'")
        temp = temp.replacingOccurrences(of: "&nbsp;", with: " ")
        return temp.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if let converted {
                Text(converted)
            } else {
                Text(fallbackText)
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

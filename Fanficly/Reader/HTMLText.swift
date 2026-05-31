import SwiftUI

struct HTMLText: View {
    let html: String

    var body: some View {
        if let attr = Self.attributed(from: html) {
            Text(attr)
        } else {
            Text(stripped(html))
        }
    }

    private func stripped(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func attributed(from html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let ns = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        var attr = AttributedString(ns)
        attr.foregroundColor = nil
        attr.font = nil
        return attr
    }
}

import SwiftUI

struct WorkHeaderMetadata: View {
    let summary: AO3WorkSummary
    let foreground: Color
    @State private var showDetails = false

    private var hasDetails: Bool {
        !summary.fandoms.isEmpty || !summary.relationships.isEmpty
            || !summary.characters.isEmpty || !summary.freeforms.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Always visible: rating, warnings, categories, stats.
            FlowLayout(spacing: 6, lineSpacing: 6) {
                RatingBadge(rating: summary.rating)
                ForEach(summary.warnings, id: \.self) { warning in
                    SmallChip(text: warning, kind: .warning)
                }
                ForEach(summary.categories, id: \.self) { category in
                    SmallChip(text: category, kind: .category)
                }
            }

            StatsRow(summary: summary, foreground: foreground)

            // Collapsible: fandoms, relationships, characters, tags.
            if hasDetails {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showDetails.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(showDetails ? "Hide tags & relationships" : "Tags & relationships")
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                if showDetails {
                    VStack(alignment: .leading, spacing: 10) {
                        if !summary.fandoms.isEmpty {
                            MetadataRow(label: "Fandom", values: summary.fandoms, kind: .fandom, foreground: foreground)
                        }
                        if !summary.relationships.isEmpty {
                            MetadataRow(label: "Relationship", values: summary.relationships, kind: .relationship, foreground: foreground)
                        }
                        if !summary.characters.isEmpty {
                            MetadataRow(label: "Characters", values: summary.characters, kind: .character, foreground: foreground)
                        }
                        if !summary.freeforms.isEmpty {
                            MetadataRow(label: "Tags", values: summary.freeforms, kind: .tag, foreground: foreground)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

private struct MetadataRow: View {
    let label: String
    let values: [String]
    let kind: ChipKind
    let foreground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.smallCaps())
                .foregroundStyle(foreground.opacity(0.55))
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(values, id: \.self) { value in
                    SmallChip(text: value, kind: kind)
                }
            }
        }
    }
}

enum ChipKind {
    case rating, warning, category, fandom, relationship, character, tag

    var foreground: Color {
        switch self {
        case .rating:       .white
        case .warning:      .red
        case .category:     .indigo
        case .fandom:       .blue
        case .relationship: .pink
        case .character:    .teal
        case .tag:          .accentColor
        }
    }

    var background: Color {
        switch self {
        case .rating: Color.red
        default:      foreground.opacity(0.15)
        }
    }
}

private struct SmallChip: View {
    let text: String
    let kind: ChipKind

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(kind.background)
            .foregroundStyle(kind.foreground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RatingBadge: View {
    let rating: String

    var body: some View {
        let (color, abbrev) = badge(for: rating)
        Text(abbrev)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .accessibilityLabel(rating)
    }

    private func badge(for rating: String) -> (Color, String) {
        switch rating {
        case "Explicit":               return (.red,      "E")
        case "Mature":                 return (.orange,   "M")
        case "Teen And Up Audiences":  return (.yellow,   "T")
        case "General Audiences":      return (.green,    "G")
        default:                       return (.gray,     "?")
        }
    }
}

private struct StatsRow: View {
    let summary: AO3WorkSummary
    let foreground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                stat("textformat.alt", "\(summary.wordCount.formatted()) words")
                stat("doc.text", chapterText)
                if summary.kudos > 0 { stat("heart", summary.kudos.formatted()) }
                if summary.hits > 0  { stat("eye",   summary.hits.formatted()) }
            }
            if let date = summary.updatedAt {
                Text("Updated \(date, style: .date) · \(summary.language)")
                    .font(.caption2)
                    .foregroundStyle(foreground.opacity(0.55))
            } else if !summary.language.isEmpty {
                Text(summary.language)
                    .font(.caption2)
                    .foregroundStyle(foreground.opacity(0.55))
            }
        }
    }

    private var chapterText: String {
        if let total = summary.totalChapters {
            return summary.chapterCount == total
                ? "\(total) ch\(total == 1 ? "" : "s") · complete"
                : "\(summary.chapterCount) / \(total) · WIP"
        }
        return "\(summary.chapterCount) / ? · WIP"
    }

    private func stat(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2)
            Text(value).font(.caption)
        }
        .foregroundStyle(foreground.opacity(0.75))
    }
}

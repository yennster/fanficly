import SwiftUI

struct SearchHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("How search works")
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.top)

                    Text("Type anything — AO3 searches titles, summaries, tags and authors, and a work has to match every word. A few distinctive words beat a long sentence.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)

                    Divider()

                    HelpSection(
                        title: "Tap a suggestion for an exact tag",
                        icon: "tag.fill",
                        color: .blue,
                        examples: [
                            ("teen wolf", "Suggests the Teen Wolf (TV) fandom — tap it to filter by the tag instead of the words."),
                            ("derek stiles", "Suggests their ship and characters."),
                            ("slow burn", "Suggests the Slow Burn tag."),
                        ]
                    )

                    HelpSection(
                        title: "Filters",
                        icon: "line.3.horizontal.decrease.circle.fill",
                        color: .purple,
                        examples: [
                            ("Filters button", "Rating, warnings, categories, complete or in progress, length, language, sort and more."),
                        ]
                    )

                    HelpSection(
                        title: "Shortcuts you can type",
                        icon: "bolt.fill",
                        color: .orange,
                        examples: [
                            ("complete · wip · one shot", "Completion and single-chapter works."),
                            ("explicit · nsfw · sfw", "Ratings (\"teen\" and \"mature\" stay words — use a suggestion or Filters)."),
                            ("m/m · f/f · f/m", "Categories."),
                            ("under 10k · over 50k · between 10k and 50k", "Word count."),
                            ("in spanish · no crossovers · no mcd", "Language, crossovers, and leaving out Major Character Death."),
                        ]
                    )

                    HelpSection(
                        title: "Precise searching",
                        icon: "scope",
                        color: .green,
                        examples: [
                            ("\"enemies to lovers\"", "An exact phrase."),
                            ("-angst", "Leave out works mentioning a word."),
                            ("title:\"The Long Way Home\"", "Search titles only."),
                            ("by:astolat", "Works by an author."),
                            ("tag:\"Slow Burn\" -tag:\"Major Character Death\"", "Include or exclude an exact tag."),
                        ]
                    )
                }
                .padding(.horizontal)
            }
            .navigationTitle("Search Tips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct HelpSection: View {
    let title: String
    let icon: String
    let color: Color
    let examples: [(query: String, description: String)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.headline)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                ForEach(examples, id: \.query) { example in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(example.query)
                            .font(.system(.subheadline, design: .monospaced))
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(4)
                        Text(example.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 8)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

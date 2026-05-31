import Foundation

protocol SearchEnricher: Sendable {
    func enrich(filters: AO3SearchFilters, prompt: String) async -> AO3SearchFilters
}

struct NoopEnricher: SearchEnricher {
    func enrich(filters: AO3SearchFilters, prompt: String) async -> AO3SearchFilters { filters }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct AO3PromptExtraction {
    @Guide(description: "Character names mentioned in the user's query, capitalised as in fandom canon, e.g. 'Hermione Granger'. Empty if none.")
    var characters: [String]

    @Guide(description: "Fandom names mentioned, e.g. 'Harry Potter - J. K. Rowling' or 'Marvel Cinematic Universe'. Empty if none.")
    var fandoms: [String]

    @Guide(description: "Tropes or freeform tags, e.g. 'Slow Burn', 'Hurt/Comfort'. Empty if none.")
    var freeforms: [String]

    @Guide(description: "Words to exclude (e.g. tropes the user said they don't want). Empty if none.")
    var excluded: [String]
}

@available(iOS 26.0, *)
struct FoundationModelsEnricher: SearchEnricher {
    func enrich(filters: AO3SearchFilters, prompt: String) async -> AO3SearchFilters {
        guard !prompt.isEmpty else { return filters }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return filters }

        let session = LanguageModelSession(
            instructions: """
            You are helping refine an Archive of Our Own (AO3) search. From the user's text, extract:
            - characters (proper nouns, fandom-canon capitalisation)
            - fandoms (the work's source canon)
            - freeforms (tropes / additional tags)
            - excluded (things the user said they don't want)

            Be conservative. Only include items the user clearly intends. Leave arrays empty if unsure.
            """
        )
        do {
            let response = try await session.respond(
                to: prompt,
                generating: AO3PromptExtraction.self
            )
            var enriched = filters
            for name in response.content.characters where !enriched.characterNames.contains(name) {
                enriched.characterNames.append(name)
            }
            for name in response.content.fandoms where !enriched.fandomNames.contains(name) {
                enriched.fandomNames.append(name)
            }
            for name in response.content.freeforms where !enriched.freeformNames.contains(name) {
                enriched.freeformNames.append(name)
            }
            for name in response.content.excluded where !enriched.excludedFreeforms.contains(name) {
                enriched.excludedFreeforms.append(name)
            }
            if !response.content.characters.isEmpty
                || !response.content.fandoms.isEmpty
                || !response.content.freeforms.isEmpty {
                enriched.query = ""
            }
            return enriched
        } catch {
            return filters
        }
    }
}
#endif

enum SearchEnricherFactory {
    static func make() -> any SearchEnricher {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return FoundationModelsEnricher()
        }
        #endif
        return NoopEnricher()
    }
}

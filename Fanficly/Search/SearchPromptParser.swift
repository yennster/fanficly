import Foundation

public struct SearchPromptParser: Sendable {
    public init() {}

    public func parse(_ prompt: String) -> AO3SearchFilters {
        var filters = AO3SearchFilters()
        
        let normalizedPrompt = prompt
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            
        let working = NSMutableString(string: normalizedPrompt.lowercased())
        let casedWorking = NSMutableString(string: normalizedPrompt)

        extractTitle(from: working, casedWorking: casedWorking, into: &filters)
        extractCreators(from: working, casedWorking: casedWorking, into: &filters)
        extractExclusions(from: working, into: &filters)
        extractQuoted(from: working, into: &filters)
        extractShips(from: working, into: &filters)
        extractWordCount(from: working, into: &filters)
        extractEngagement(from: working, into: &filters)
        extractStatus(from: working, into: &filters)
        extractCrossover(from: working, into: &filters)
        extractLanguage(from: working, into: &filters)
        extractCategories(from: working, into: &filters)
        extractRatings(from: working, into: &filters)
        extractWarnings(from: working, into: &filters)
        extractFandoms(from: working, into: &filters)
        extractFreeformTags(from: working, into: &filters)

        let remainder = collapseWhitespace(working as String)
        if !remainder.isEmpty {
            filters.query = remainder
        }
        return filters
    }

    private func extractTitle(from working: NSMutableString, casedWorking: NSMutableString, into filters: inout AO3SearchFilters) {
        let patterns = [
            #"title:\s*"([^"]+)""#,
            #"title:\s*([^\s]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: working as String, range: NSRange(location: 0, length: working.length))
            for match in matches.reversed() where match.numberOfRanges > 1 {
                let nsRange = match.range(at: 1)
                let extractedTitle = casedWorking.substring(with: nsRange).trimmingCharacters(in: .whitespaces)
                if !extractedTitle.isEmpty {
                    filters.title = extractedTitle
                }
                working.deleteCharacters(in: match.range)
                casedWorking.deleteCharacters(in: match.range)
            }
        }
    }

    private func extractCreators(from working: NSMutableString, casedWorking: NSMutableString, into filters: inout AO3SearchFilters) {
        let patterns = [
            #"\b(?:author|creator|creators|by):\s*"([^"]+)""#,
            #"\b(?:author|creator|creators|by):\s*([^\s]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = regex.matches(in: working as String, range: NSRange(location: 0, length: working.length))
            for match in matches.reversed() where match.numberOfRanges > 1 {
                let nsRange = match.range(at: 1)
                let extractedCreators = casedWorking.substring(with: nsRange).trimmingCharacters(in: .whitespaces)
                if !extractedCreators.isEmpty {
                    filters.creators = extractedCreators
                }
                working.deleteCharacters(in: match.range)
                casedWorking.deleteCharacters(in: match.range)
            }
        }
    }

    private func extractExclusions(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        let patterns = [
            #"(?:^|\s)-"([^"]+)""#,
            #"(?:^|\s)-([a-z0-9][a-z0-9'\-]*)\b"#,
            #"(?:^|\s)not\s+"([^"]+)""#,
            #"(?:^|\s)not\s+([a-z0-9][a-z0-9'\-]*)\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: working as String, range: NSRange(location: 0, length: working.length))
            for match in matches.reversed() where match.numberOfRanges > 1 {
                let term = (working.substring(with: match.range(at: 1)))
                    .trimmingCharacters(in: .whitespaces)
                if !term.isEmpty {
                    filters.excludedFreeforms.append(term)
                }
                working.deleteCharacters(in: match.range)
            }
        }
    }

    /// Pulls out double-quoted phrases as exact tags before the ship regex can
    /// mangle them — so `"Hermione Granger/Draco Malfoy"` stays one relationship
    /// instead of the ship matcher grabbing "granger/draco". A quoted phrase with
    /// a slash is a relationship; otherwise it's a freeform tag. (Exclusions like
    /// `-"…"` were already consumed above.) Resolution later canonicalizes it.
    private func extractQuoted(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]+)""#) else { return }
        let matches = regex.matches(in: working as String, range: NSRange(location: 0, length: working.length))
        for match in matches.reversed() where match.numberOfRanges > 1 {
            let phrase = working.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !phrase.isEmpty {
                if phrase.contains("/") {
                    filters.relationshipNames.append(phrase.capitalized)
                } else {
                    filters.freeformNames.append(phrase.capitalized)
                }
            }
            working.deleteCharacters(in: match.range)
        }
    }

    private func extractShips(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        let pattern = #"(?<![\w/])([a-z][a-z'\-]+)\/([a-z][a-z'\-]+)(?![\w/])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: working as String, range: NSRange(location: 0, length: working.length))
        for match in matches.reversed() where match.numberOfRanges == 3 {
            let left = working.substring(with: match.range(at: 1))
            let right = working.substring(with: match.range(at: 2))
            if let category = KnownTags.categoryAliases["\(left)/\(right)"] {
                filters.categories.insert(category)
            } else {
                let ship = "\(left.capitalized)/\(right.capitalized)"
                filters.relationshipNames.append(ship)
            }
            working.deleteCharacters(in: match.range)
        }
    }

    private func extractWordCount(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        struct Pattern {
            let regex: String
            let render: (Int, Int?) -> String
        }
        let kSuffix = #"(?:k|,000)"#
        let patterns: [Pattern] = [
            Pattern(regex: #"under\s+(\d+)\s*\#(kSuffix)?"#) { n, _ in "<\(n)" },
            Pattern(regex: #"over\s+(\d+)\s*\#(kSuffix)?"#) { n, _ in ">\(n)" },
            Pattern(regex: #"more than\s+(\d+)\s*\#(kSuffix)?"#) { n, _ in ">\(n)" },
            Pattern(regex: #"less than\s+(\d+)\s*\#(kSuffix)?"#) { n, _ in "<\(n)" },
            Pattern(regex: #"between\s+(\d+)\s*\#(kSuffix)?\s+and\s+(\d+)\s*\#(kSuffix)?"#) { lo, hi in
                if let hi { return "\(lo)-\(hi)" } else { return "\(lo)" }
            },
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern.regex) else { continue }
            let str = working as String
            let matches = regex.matches(in: str, range: NSRange(location: 0, length: working.length))
            for match in matches.reversed() {
                let raw1 = working.substring(with: match.range(at: 1))
                let full = working.substring(with: match.range)
                let hadK = full.contains("k") || full.contains(",000")
                let n1 = (Int(raw1) ?? 0) * (hadK ? 1_000 : 1)
                var n2: Int?
                if match.numberOfRanges > 2 {
                    let r2 = match.range(at: 2)
                    if r2.location != NSNotFound {
                        let raw2 = working.substring(with: r2)
                        let hadK2 = full.range(of: raw2 + "k") != nil || full.range(of: raw2 + ",000") != nil
                        n2 = (Int(raw2) ?? 0) * (hadK2 ? 1_000 : 1)
                    }
                }
                filters.wordCount = pattern.render(n1, n2)
                working.deleteCharacters(in: match.range)
            }
        }
    }

    private func extractEngagement(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        if removeFirst(in: working, pattern: #"\bpopular\b"#) {
            filters.kudosCount = ">1000"
        }
        if removeFirst(in: working, pattern: #"\bmost kudos\b"#) {
            filters.sortColumn = .kudosCount
            filters.sortDirection = .desc
        }
        if removeFirst(in: working, pattern: #"\bmost hits\b"#) {
            filters.sortColumn = .hits
            filters.sortDirection = .desc
        }
        if removeFirst(in: working, pattern: #"\brecently updated\b"#) {
            filters.sortColumn = .revisedAt
            filters.sortDirection = .desc
        }
        if removeFirst(in: working, pattern: #"\bnewest\b|\brecent\b"#) {
            filters.sortColumn = .createdAt
            filters.sortDirection = .desc
        }
    }

    private func extractStatus(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        if removeFirst(in: working, pattern: #"\boneshot\b|\bone\s*-?\s*shot\b|\bone shot\b"#) {
            filters.singleChapter = true
        }
        if removeFirst(in: working, pattern: #"\bcomplete\b|\bcompleted\b|\bfinished\b"#) {
            filters.complete = .yes
        }
        if removeFirst(in: working, pattern: #"\bwip\b|\bwork in progress\b|\bin progress\b|\bunfinished\b"#) {
            filters.complete = .no
        }
    }

    private func extractCrossover(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        if removeFirst(in: working, pattern: #"\bno\s+crossovers?\b"#) {
            filters.crossover = .no
        } else if removeFirst(in: working, pattern: #"\bcrossovers?\b"#) {
            filters.crossover = .yes
        }
    }

    private func extractLanguage(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        for (alias, code) in KnownTags.languageAliases {
            let escaped = NSRegularExpression.escapedPattern(for: alias)
            if removeFirst(in: working, pattern: #"\b\#(escaped)\b"#) {
                filters.languageId = code
                return
            }
        }
    }

    private func extractCategories(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        for (alias, category) in KnownTags.categoryAliases {
            let escaped = NSRegularExpression.escapedPattern(for: alias)
            if removeFirst(in: working, pattern: #"(?<![\w/])\#(escaped)(?![\w/])"#) {
                filters.categories.insert(category)
            }
        }
    }

    private func extractRatings(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        let sortedKeys = KnownTags.ratingAliases.keys.sorted { $0.count > $1.count }
        for alias in sortedKeys {
            guard let rating = KnownTags.ratingAliases[alias] else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: alias)
            let pattern = alias.count == 1 ? #"\b\#(escaped)-rated\b"# : #"\b\#(escaped)\b"#
            if removeFirst(in: working, pattern: pattern) {
                filters.ratings.insert(rating)
            }
        }
    }

    private func extractWarnings(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        let sortedKeys = KnownTags.warningAliases.keys.sorted { $0.count > $1.count }
        for alias in sortedKeys {
            guard let warning = KnownTags.warningAliases[alias] else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: alias)
            if removeFirst(in: working, pattern: #"\b\#(escaped)\b"#) {
                filters.warnings.insert(warning)
            }
        }
    }

    private func extractFreeformTags(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        let sortedTags = KnownTags.freeformTags.sorted { $0.count > $1.count }
        for tag in sortedTags {
            let escaped = NSRegularExpression.escapedPattern(for: tag)
            if removeFirst(in: working, pattern: #"\b\#(escaped)\b"#) {
                filters.freeformNames.append(canonicalize(tag))
            }
        }
    }

    private func extractFandoms(from working: NSMutableString, into filters: inout AO3SearchFilters) {
        let sortedAliases = KnownTags.fandomAliases.keys.sorted { $0.count > $1.count }
        for alias in sortedAliases {
            guard let canonical = KnownTags.fandomAliases[alias] else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: alias)
            if removeFirst(in: working, pattern: #"\b\#(escaped)\b"#) {
                if !filters.fandomNames.contains(canonical) {
                    filters.fandomNames.append(canonical)
                }
            }
        }
    }

    private func canonicalize(_ tag: String) -> String {
        tag.split(separator: " ").map { word in
            let lower = word.lowercased()
            if lower == "of" || lower == "and" || lower == "the" || lower == "to" || lower == "a" {
                return lower
            }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    @discardableResult
    private func removeFirst(in working: NSMutableString, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: working.length)
        guard let match = regex.firstMatch(in: working as String, range: range) else { return false }
        working.deleteCharacters(in: match.range)
        return true
    }

    private func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

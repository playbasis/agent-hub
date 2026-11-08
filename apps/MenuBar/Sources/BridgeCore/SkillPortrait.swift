import Foundation

/// Decorative category, never a provider identity or measured classification.
/// Versioned, local and independent of load counts, model or refresh timing.
public enum SkillPortrait: String, CaseIterable, Sendable {
    case research, build, review, design, release, knowledge

    public var title: String { rawValue.capitalized }

    public static func automatic(for name: String) -> SkillPortrait {
        let words = Set(name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let rules: [(SkillPortrait, Set<String>)] = [
            (.release, ["release", "deploy", "deployment", "publish", "shipping"]),
            (.design, ["figma", "design", "image", "imagegen", "visualize", "motion", "shader", "shaders", "artist"]),
            (.review, ["review", "security", "scan", "audit", "test", "tests", "testing", "eval", "evaluation", "validation", "verify", "risk", "assess"]),
            (.research, ["search", "research", "discovery", "enrich", "ingestion", "source", "diagnostics"]),
            (.knowledge, ["docs", "documents", "pdf", "pages", "page", "log", "catalog", "lyrics", "presentations", "spreadsheets", "instructions"]),
        ]
        return rules.first { !words.isDisjoint(with: $0.1) }?.0 ?? .build
    }

    public static func resolve(name: String, override: String) -> SkillPortrait {
        SkillPortrait(rawValue: override) ?? automatic(for: name)
    }
}

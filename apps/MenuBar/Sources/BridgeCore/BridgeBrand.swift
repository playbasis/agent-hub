import Foundation

/// User-facing product identity. The repository, bundle identifier, data
/// directory and installed bundle path keep the ClaudeCodexBridge codename so
/// hooks, Keychain identity and saved state survive the rename.
public enum BridgeBrand {
    public static let productName = "Playbasis AI Agent Hub"
    /// Short form for tight spaces: window chrome, the panel and sentences.
    public static let shortName = "Agent Hub"
    public static let company = "Playbasis"
}

/// Plain-language names for provider model identifiers and effort levels.
/// Raw identifiers stay available in tooltips and the inspector.
public enum ModelNaming {
    /// `gpt-6.1-terra` → "GPT-6.1 Terra", `claude-opus-5-5` → "Claude Opus 5.5",
    /// `claude-sonnet-4-5-20250929` → "Claude Sonnet 4.5", `gemini-3.5-flash`
    /// → "Gemini 3.5 Flash". Unknown shapes are title-cased, never dropped.
    public static func display(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "Unknown model" }
        var parts = raw.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init)
        // Trailing release dates (20250929) and "latest" are noise to people.
        while let last = parts.last, (last.count == 8 && last.allSatisfy(\.isNumber)) || last == "latest" { parts.removeLast() }
        guard let brand = parts.first else { return raw }

        switch brand {
        case "gpt", "glm":
            let rest = Array(parts.dropFirst())
            guard let version = rest.first, isVersion(version) else { return words(parts, upper: [brand]) }
            return ([brand.uppercased() + "-" + version] + rest.dropFirst().map(word)).joined(separator: " ")
        case "claude", "gemini", "grok", "llama", "mistral", "qwen", "deepseek":
            var output = [word(brand)]
            var index = 1
            var version: [String] = []
            while index < parts.count {
                let part = parts[index]
                if isVersion(part) {
                    version.append(part)
                } else {
                    if !version.isEmpty { output.append(version.joined(separator: ".")); version = [] }
                    output.append(word(part))
                }
                index += 1
            }
            if !version.isEmpty { output.append(version.joined(separator: ".")) }
            return output.joined(separator: " ")
        default:
            // o3, o4-mini and other compact families read best as written.
            if brand.count <= 3, brand.first == "o", brand.dropFirst().allSatisfy(\.isNumber) {
                return ([brand] + parts.dropFirst().map(word)).joined(separator: " ")
            }
            return words(parts, upper: [])
        }
    }

    /// Provider effort identifiers in everyday words.
    public static func effort(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return "Default effort" }
        switch raw {
        case "xhigh", "x-high", "extra-high", "extra_high": return "Extra high"
        case "max", "maximum": return "Maximum"
        default: return word(raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " "))
        }
    }

    /// Display name of the subscription people recognise for each provider.
    public static func planOwner(_ agent: AgentName) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        case .grok: return "Grok"
        case .none: return "Unknown"
        }
    }

    private static func isVersion(_ part: String) -> Bool {
        guard let first = part.first, first.isNumber else { return false }
        return part.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func word(_ part: String) -> String {
        guard let first = part.first else { return part }
        if part.allSatisfy({ $0.isNumber || $0 == "." }) { return part }
        return first.uppercased() + part.dropFirst()
    }

    private static func words(_ parts: [String], upper: Set<String>) -> String {
        parts.map { upper.contains($0) ? $0.uppercased() : word($0) }.joined(separator: " ")
    }
}

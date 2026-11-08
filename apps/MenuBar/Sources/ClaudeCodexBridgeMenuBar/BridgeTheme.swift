import AppKit
import BridgeCore
import SwiftUI

/// Six bounded, shared image decodes. Missing artwork falls back to a glyph.
enum SkillPortraitArtwork {
    static func url(for portrait: SkillPortrait) -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.resourceURL?.appendingPathComponent("SkillPortraits/\(portrait.rawValue).png")
        }
        return Bundle.module.url(forResource: portrait.rawValue, withExtension: "png", subdirectory: "SkillPortraits")
    }
    private static let images: [SkillPortrait: NSImage] = Dictionary(uniqueKeysWithValues:
        SkillPortrait.allCases.compactMap { portrait in
            guard let url = url(for: portrait), let image = NSImage(contentsOf: url) else { return nil }
            image.isTemplate = false
            image.size = NSSize(width: 128, height: 128)
            return (portrait, image)
        })
    static func image(for portrait: SkillPortrait) -> NSImage? { images[portrait] }
}

/// Tool identity stays separate from provider and usage. No circle or tile
/// backdrop: the PNG's real alpha adapts to the surrounding surface.
struct SkillMonogram: View {
    var name: String
    var providers: [AgentName]
    var size: CGFloat
    var dimmed: Bool
    @AppStorage private var overrideID: String
    init(name: String, providers: [AgentName], size: CGFloat, dimmed: Bool) {
        self.name = name; self.providers = providers; self.size = size; self.dimmed = dimmed
        _overrideID = AppStorage(wrappedValue: "", "skillPortrait.v1.\(name)")
    }
    var body: some View {
        let portrait = SkillPortrait.resolve(name: name, override: overrideID)
        Group {
            if let image = SkillPortraitArtwork.image(for: portrait) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "square.stack.3d.up").resizable().scaledToFit()
                    .padding(size * 0.2).foregroundStyle(BridgeTheme.brand)
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.65 : 1)
        .accessibilityHidden(true)
    }
}

/// Keyboard-accessible in the skill detail's actions menu.
struct SkillPortraitMenu: View {
    var name: String
    @AppStorage private var overrideID: String
    init(name: String) {
        self.name = name
        _overrideID = AppStorage(wrappedValue: "", "skillPortrait.v1.\(name)")
    }
    var body: some View {
        Menu("Picture") {
            Button("Automatic (\(SkillPortrait.automatic(for: name).title))") { overrideID = "" }
            Divider()
            ForEach(SkillPortrait.allCases, id: \.rawValue) { portrait in
                Button { overrideID = portrait.rawValue } label: {
                    if overrideID == portrait.rawValue { Label(portrait.title, systemImage: "checkmark") }
                    else { Text(portrait.title) }
                }
            }
        }
    }
}

// MARK: - Tokens

/// The Agent Hub design system: neutral layered surfaces, hairline borders and
/// one type scale. Colour carries meaning: agent identity (Claude coral, Codex
/// teal, Gemini blue), state, the Playbasis brand, and highlight tone.
enum BridgeTheme {
    // Identity
    static let claude = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let codex = Color(red: 16 / 255, green: 163 / 255, blue: 127 / 255)
    static let gemini = Color(red: 86 / 255, green: 143 / 255, blue: 255 / 255)
    static let grok = Color(red: 232 / 255, green: 92 / 255, blue: 160 / 255)
    static let glm = Color(red: 151 / 255, green: 176 / 255, blue: 255 / 255)

    // Playbasis brand, sampled from the "P" mark and lifted for dark surfaces.
    static let brand = Color(red: 34 / 255, green: 186 / 255, blue: 214 / 255)
    static let brandDeep = Color(red: 38 / 255, green: 96 / 255, blue: 196 / 255)

    // State
    static let success = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    static let warning = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
    static let danger = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)

    // Text
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.34)

    // Surfaces
    static let ink = Color(red: 22 / 255, green: 22 / 255, blue: 24 / 255)
    static let inkRaised = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let surface = Color.white.opacity(0.045)
    static let surfaceBorder = Color.white.opacity(0.07)
    static let well = Color.black.opacity(0.22)
    static let wellBorder = Color.white.opacity(0.06)
    static let separator = Color.white.opacity(0.07)
    // Loading content is decorative, but remains distinguishable in increased
    // contrast and follows the system foreground in both appearances.
    static func hydrationDot(increasedContrast: Bool) -> Color { Color.primary.opacity(increasedContrast ? 0.16 : 0.06) }
    static func hydrationGhost(increasedContrast: Bool) -> Color { Color.primary.opacity(increasedContrast ? 0.20 : 0.07) }
    static func hydrationBorder(increasedContrast: Bool) -> Color { Color.primary.opacity(increasedContrast ? 0.25 : 0.07) }
    static let hydrationSurface = Color.primary.opacity(0.045)
    static let hydrationLabel = Color.secondary
    static let control = Color.white.opacity(0.08)
    static let controlPressed = Color.white.opacity(0.14)

    // Geometry
    static let radiusCard: CGFloat = 10
    static let radiusWell: CGFloat = 8
    static let radiusControl: CGFloat = 7

    /// Highlight tone: alerts red, watch-items amber, unusual patterns in the
    /// brand cyan, good news green and context neutral.
    static func tone(_ tone: ActivityHighlight.Tone) -> Color {
        switch tone {
        case .alert: return danger
        case .warning: return warning
        case .notable: return brand
        case .positive: return success
        case .neutral: return Color.white.opacity(0.62)
        }
    }

    static func color(for agent: AgentName) -> Color {
        switch agent {
        case .claude: return claude
        case .codex: return codex
        case .grok: return grok
        case .none: return textSecondary
        }
    }

    /// Parts of what a session starts with: project rules in the brand cyan,
    /// the person's own rules in deep blue, memory violet, the skill list slate.
    static func startPart(_ part: InstructionReport.Part) -> Color {
        switch part {
        case .project: return brand
        case .personal: return brandDeep
        case .memory: return categoryPalette[3]
        case .skills: return categoryPalette[0]
        }
    }

    /// Whether two agents read the same project rules.
    static func parity(_ parity: ProjectInstructions.Parity) -> Color {
        switch parity {
        case .same: return success
        case .overlap: return brand
        case .different, .claudeOnly, .codexOnly: return warning
        case .none: return textTertiary
        }
    }

    /// Muted categorical palette for work categories in charts. Identity
    /// colours stay reserved for agents; these never compete with them.
    static let categoryPalette: [Color] = [
        Color(red: 0.55, green: 0.63, blue: 0.80),
        Color(red: 0.62, green: 0.76, blue: 0.62),
        Color(red: 0.84, green: 0.73, blue: 0.52),
        Color(red: 0.74, green: 0.60, blue: 0.80),
        Color(red: 0.52, green: 0.74, blue: 0.78),
        Color(red: 0.82, green: 0.60, blue: 0.62),
        Color(red: 0.70, green: 0.70, blue: 0.55),
        Color(red: 0.60, green: 0.66, blue: 0.70),
    ]

    /// Known tool categories get fixed, distinct colours so a category reads
    /// the same in every chart; unknown names fall back to a stable hash.
    static let knownCategoryColors: [String: Color] = [
        "Execution": categoryPalette[0],
        "Research": categoryPalette[1],
        "Tests": categoryPalette[2],
        "Implementation": categoryPalette[3],
        "Review": categoryPalette[4],
        "Coordination": categoryPalette[5],
        "Inspection": categoryPalette[6],
        "Delegation": categoryPalette[7],
    ]

    /// SF Symbol for a work category, used in legends and hover details.
    static func categorySymbol(_ name: String) -> String {
        switch name {
        case "Execution": return "terminal"
        case "Research": return "magnifyingglass"
        case "Tests": return "checkmark.circle"
        case "Implementation": return "chevron.left.forwardslash.chevron.right"
        case "Review": return "eye"
        case "Coordination": return "point.3.connected.trianglepath.dotted"
        case "Inspection": return "doc.text.magnifyingglass"
        case "Delegation": return "person.2"
        default: return "circle.dashed"
        }
    }

    static func category(_ name: String, in ordered: [String] = []) -> Color {
        if name == "Other" { return Color.white.opacity(0.22) }
        if let known = knownCategoryColors[name] { return known }
        // Do not recolor a category when filtering changes its rank. Swift's
        // randomized Hasher is unsuitable for persistent visual identity.
        let hash = name.lowercased().utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return categoryPalette[Int(hash % UInt64(categoryPalette.count))]
    }

    static func color(forParticipant name: String) -> Color {
        switch name.lowercased() {
        case "claude": return claude
        case "codex": return codex
        case "gemini": return gemini
        case "grok": return grok
        case "glm", "z.ai": return glm
        default: return Color.white.opacity(0.28)
        }
    }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// The type scale. Every label in the app uses one of these.
enum BridgeFont {
    static let title = Font.system(size: 15, weight: .semibold)
    static let heading = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let secondary = Font.system(size: 12)
    static let secondaryMedium = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let micro = Font.system(size: 10, weight: .medium)
    static let mono = Font.system(size: 11, design: .monospaced)
    static let numeral = Font.system(size: 12, weight: .semibold).monospacedDigit()
}

// MARK: - Provider artwork

/// Provider-sourced artwork, cached by AppKit. SVGs stay vector at Retina sizes.
/// Original colours are preserved; only the monochrome Grok mark is templated.
enum ProviderArtwork {
    static func image(for name: String) -> NSImage? {
        let key: String
        switch name.lowercased() {
        case "claude": key = "claude"
        case "codex", "chatgpt", "openai": key = "openai"
        case "gemini": key = "gemini"
        case "grok": key = "grok"
        default: return nil
        }
        let cacheName = NSImage.Name("Bridge.Provider." + key)
        if let cached = NSImage(named: cacheName) { return cached }
        let ext = key == "gemini" ? "png" : "svg"
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("ProviderLogos/\(key).\(ext)")
        let url: URL?
        if let packaged, FileManager.default.fileExists(atPath: packaged.path) {
            url = packaged
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            url = nil
        } else {
            url = Bundle.module.url(forResource: key, withExtension: ext, subdirectory: "ProviderLogos")
        }
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = key == "grok"
        image.setName(cacheName)
        return image
    }
}

/// A neutral identity well with original provider artwork.
/// `active` draws a thin outer ring; `thinking` animates a rotating arc.
struct AgentAvatar: View {
    var name: String
    var size: CGFloat = 24
    var active = false
    var thinking = false
    var dimmed = false

    private var tint: Color { BridgeTheme.color(forParticipant: name) }

    var body: some View {
        ZStack {
            Circle()
                .fill(BridgeTheme.control)
                .overlay(Circle().strokeBorder(BridgeTheme.surfaceBorder, lineWidth: 0.5))
                .frame(width: size, height: size)
            glyph
                .frame(width: size * 0.76, height: size * 0.76)
            if active {
                Circle()
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5)
                    .frame(width: size + 6, height: size + 6)
            }
            if thinking {
                ThinkingRing(tint: tint, lineWidth: 1.5)
                    .frame(width: size + 8, height: size + 8)
            }
        }
        .frame(width: size + 8, height: size + 8)
        .opacity(dimmed ? 0.4 : 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if let artwork = ProviderArtwork.image(for: name) {
            Image(nsImage: artwork)
                .renderingMode(name.lowercased() == "grok" ? .template : .original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(BridgeTheme.textPrimary)
        } else {
        switch name.lowercased() {
        case "you": Image(systemName: "person.fill").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
        case "room", "team", "lead": Image(systemName: "sparkles").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
        default:
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        }
    }
}

struct ThinkingRing: View {
    var tint: Color
    var lineWidth: CGFloat = 1.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: BridgeTheme.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(BridgeTheme.reduceMotion ? 0 : (t * 200).truncatingRemainder(dividingBy: 360)))
        }
    }
}

// MARK: - Gauges

/// Circular usage gauge. The bright arc is what remains; the colour turns
/// amber past 75% used and red past 90%.
struct RingGauge: View {
    var usedRatio: Double
    var tint: Color
    var size: CGFloat = 44
    var lineWidth: CGFloat = 4
    var label: String? = nil

    static func remainingRatio(_ used: Double) -> Double? {
        guard used.isFinite, (0...1).contains(used) else { return nil }
        return 1 - used
    }
    private var remaining: Double { Self.remainingRatio(usedRatio) ?? 0 }

    private var ringColor: Color {
        if Self.remainingRatio(usedRatio) == nil { return BridgeTheme.textTertiary }
        if usedRatio >= 0.9 { return BridgeTheme.danger }
        if usedRatio >= 0.75 { return BridgeTheme.warning }
        return tint
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: remaining)
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: remaining)
            Text(Self.remainingRatio(usedRatio).map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                .font(.system(size: size * 0.28, weight: .semibold).monospacedDigit())
                .foregroundStyle(BridgeTheme.textPrimary)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "Usage")
        .accessibilityValue(Self.remainingRatio(usedRatio).map { "\(Int(($0 * 100).rounded())) percent remaining" } ?? "Capacity unavailable")
    }
}

// MARK: - Surfaces

extension View {
    /// A raised card: faint fill, hairline border, 10pt corners.
    func bridgeCard(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: BridgeTheme.radiusCard, style: .continuous)
                    .fill(BridgeTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BridgeTheme.radiusCard, style: .continuous)
                    .strokeBorder(BridgeTheme.surfaceBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }

    /// A recessed well for inputs and nested content.
    func bridgeWell(cornerRadius: CGFloat = BridgeTheme.radiusWell) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(BridgeTheme.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(BridgeTheme.wellBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

/// Section header: sentence case, secondary, 11pt medium — like macOS.
struct SectionTitle: View {
    var text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BridgeTheme.textTertiary)
                    .frame(width: 13)
            }
            Text(text)
                .font(BridgeFont.captionMedium)
                .foregroundStyle(BridgeTheme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small inline tag. Monochrome by default; colour only for state.
struct Tag: View {
    var text: String
    var color: Color? = nil

    var body: some View {
        Text(text)
            .font(BridgeFont.micro)
            .foregroundStyle(color ?? BridgeTheme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill((color ?? Color.white).opacity(color == nil ? 0.07 : 0.14))
            )
    }
}

/// Status expressed as a dot and a word, the way macOS system prefs do it.
struct StatusDot: View {
    var text: String
    var color: Color
    var font: Font = BridgeFont.caption

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(font).foregroundStyle(BridgeTheme.textSecondary)
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(BridgeTheme.separator).frame(height: 1)
    }
}

// MARK: - Controls

/// Primary action: a solid light button with dark text, like the
/// first-party desktop apps. `tint` swaps in an identity colour.
struct BridgePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color? = nil
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? BridgeFont.secondaryMedium : BridgeFont.bodyMedium)
            .foregroundStyle(tint == nil ? BridgeTheme.ink : Color.white)
            .padding(.vertical, compact ? 5 : 7)
            .padding(.horizontal, compact ? 10 : 14)
            .background(
                RoundedRectangle(cornerRadius: BridgeTheme.radiusControl, style: .continuous)
                    .fill(tint ?? Color.white.opacity(0.92))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary action: translucent neutral fill with a hairline.
struct BridgeSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var destructive = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? BridgeFont.secondaryMedium : BridgeFont.bodyMedium)
            .foregroundStyle(destructive ? BridgeTheme.danger : BridgeTheme.textPrimary)
            .padding(.vertical, compact ? 5 : 7)
            .padding(.horizontal, compact ? 10 : 14)
            .background(
                RoundedRectangle(cornerRadius: BridgeTheme.radiusControl, style: .continuous)
                    .fill(configuration.isPressed ? BridgeTheme.controlPressed : BridgeTheme.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BridgeTheme.radiusControl, style: .continuous)
                    .strokeBorder(BridgeTheme.wellBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .opacity(isEnabled ? 1 : 0.35)
    }
}

/// Text-only action for low-emphasis rows.
struct BridgeLinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var color: Color = BridgeTheme.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BridgeFont.secondaryMedium)
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.6 : 1))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}

/// Icon-only control, 24pt, square with rounded corners.
struct BridgeIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var size: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(BridgeTheme.textSecondary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? BridgeTheme.controlPressed : BridgeTheme.control)
            )
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}

/// A quiet segmented control for the panel's sections.
/// Sidebar row: quiet hover and press fills and a slightly stronger one for
/// the current page. Label colours belong to the label, so selection never
/// changes layout.
struct SidebarRowButtonStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected)
    }

    private struct Row: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @State private var hovering = false
        var body: some View {
            let fill = selected ? 0.08 : configuration.isPressed ? 0.06 : hovering ? 0.04 : 0
            configuration.label
                .background(Color.white.opacity(fill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

struct SegmentedTabs<Tab: Hashable & Identifiable & CaseIterable>: View where Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab
    var title: (Tab) -> String
    var badge: (Tab) -> Int = { _ in 0 }
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Tab.allCases)) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = tab }
                } label: {
                    HStack(spacing: 5) {
                        Text(title(tab))
                            .font(BridgeFont.secondaryMedium)
                        if badge(tab) > 0 {
                            Circle().fill(BridgeTheme.warning).frame(width: 5, height: 5)
                        }
                    }
                    .foregroundStyle(selected ? BridgeTheme.textPrimary : BridgeTheme.textSecondary)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.10))
                                .matchedGeometryEffect(id: "segment", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(BridgeTheme.wellBorder, lineWidth: 1)
        )
    }
}

import AppKit
import BridgeCore
import SwiftUI

/// Resolves only catalogued images within the app's resource bundle. A slug
/// never becomes an arbitrary filesystem path, even for a malformed snapshot.
enum PersonaArtwork {
    private static let allowedSlugs = Set(AgentPersonaCatalog.all.map(\.slug))
    private static let lock = NSLock()
    private static let cache = NSCache<NSString, NSImage>()
    private static var unavailable: Set<String> = []

    static func image(_ slug: String) -> NSImage? {
        guard allowedSlugs.contains(slug) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache.object(forKey: slug as NSString) { return cached }
        guard !unavailable.contains(slug) else { return nil }
        // Installed apps carry assets directly in Contents/Resources. Only
        // development executables may fall back to SwiftPM's resource bundle.
        let root = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.resourceURL : Bundle.module.resourceURL
        guard let root else { unavailable.insert(slug); return nil }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let url = canonicalRoot.appendingPathComponent("AgentPersonas", isDirectory: true)
            .appendingPathComponent(slug).appendingPathExtension("png")
            .resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(canonicalRoot.path + "/AgentPersonas/"),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let bytes = values.fileSize, (1...1_048_576).contains(bytes),
              let image = NSImage(contentsOf: url), image.size.width.isFinite, image.size.height.isFinite,
              (1...2_048).contains(image.size.width), (1...2_048).contains(image.size.height) else {
            unavailable.insert(slug)
            return nil
        }
        cache.countLimit = allowedSlugs.count
        cache.totalCostLimit = 16 * 1_048_576
        let decodedCost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: slug as NSString, cost: max(bytes, decodedCost))
        return image
    }
}

/// The store keeps portrait identities across snapshots, imported older
/// history and relaunches; its role remains based on current observations.
enum PersonaDirectory {
    private static let store = AgentPersonaAssignmentStore()
    static var persistenceError: String? { AcceptanceProbe.isActive ? nil : store.persistenceError }

    static func assignments(for overview: ActivityOverview) -> [String: AgentPersonaCatalog.Assignment] {
        guard !AcceptanceProbe.isActive else { return [:] }
        return store.assignments(for: overview.sessions)
    }

    static func assignment(_ sessionID: String, in overview: ActivityOverview) -> AgentPersonaCatalog.Assignment? {
        assignments(for: overview)[sessionID]
    }
}

/// WorkspaceOps-style agent portrait: a persona photo in a circle, a status
/// ring (green = a recent recorded turn), and the
/// provider's mark as a corner badge. Falls back to the provider disc when
/// personas are turned off or a portrait is missing.
struct AgentPortrait: View {
    var persona: AgentPersona?
    var provider: AgentName
    var size: CGFloat = 32
    var recent = false
    var dimmed = false
    var showBadge = true
    @AppStorage("bridge.showPersonas") private var showPersonas = true

    private var diameter: CGFloat { size.isFinite ? min(256, max(8, size)) : 32 }

    var body: some View {
        // Loading is conditional on the setting; an off toggle performs no
        // portrait resource reads and uses one full-size provider mark.
        let image = showPersonas ? persona.flatMap { PersonaArtwork.image($0.slug) } : nil
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    AgentAvatar(name: providerName, size: max(1, diameter - 8))
                }
            }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(recent ? BridgeTheme.success : BridgeTheme.surfaceBorder, lineWidth: recent ? max(1.5, diameter / 18) : 1))
            if showBadge, image != nil, diameter >= 20 {
                AgentAvatar(name: providerName, size: max(9, diameter * 0.36))
                    .background(Circle().fill(BridgeTheme.ink).padding(max(2, diameter * 0.04)))
                    .offset(x: diameter * 0.10, y: diameter * 0.10)
            }
        }
        .frame(width: diameter, height: diameter)
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityHidden(true)
    }

    private var providerName: String { provider.rawValue.capitalized }

}

/// Overlapping portrait stack, as in the WorkspaceOps top bar.
struct PortraitStack: View {
    var items: [(persona: AgentPersona?, provider: AgentName, recent: Bool)]
    var size: CGFloat = 22
    var limit = 5

    private var visibleLimit: Int { min(20, max(0, limit)) }
    private var diameter: CGFloat { size.isFinite ? min(256, max(8, size)) : 22 }

    var body: some View {
        HStack(spacing: -diameter * 0.32) {
            ForEach(Array(items.prefix(visibleLimit).enumerated()), id: \.offset) { _, item in
                AgentPortrait(persona: item.persona, provider: item.provider, size: diameter, recent: item.recent, showBadge: false)
                    .background(Circle().fill(BridgeTheme.ink).padding(-1.5))
            }
            if items.count > visibleLimit {
                Text("+\(items.count - visibleLimit)")
                    .font(.system(size: diameter * 0.4, weight: .semibold).monospacedDigit())
                    .foregroundStyle(BridgeTheme.textSecondary)
                    .frame(width: diameter, height: diameter)
                    .background(Circle().fill(BridgeTheme.inkRaised))
                    .overlay(Circle().strokeBorder(BridgeTheme.surfaceBorder, lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Small-caps status chip, as on WorkspaceOps command lanes ("IN REVIEW").
struct CapsChip: View {
    var text: String
    var color: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 8, weight: .bold)) }
            Text(text.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.6)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(color.opacity(0.22), lineWidth: 1))
    }
}

/// Big numerals with small labels, separated by hairlines — the WorkspaceOps
/// command-center summary ("100% overall ready │ 5 platforms │ 8 to approve").
struct StatStrip: View {
    struct Item: Identifiable {
        var value: String
        var label: String
        var icon: String? = nil
        var color: Color = BridgeTheme.textPrimary
        var help: String? = nil
        var id: String { label }
    }

    var items: [Item]
    var compact = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Rectangle().fill(BridgeTheme.separator).frame(width: 1, height: compact ? 26 : 34)
                    }
                    cell(item, wrapLabel: false)
                        .frame(minWidth: compact ? 72 : 105)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(3, max(1, items.count))), spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    cell(item, wrapLabel: true)
                }
            }
        }
    }

    private func cell(_ item: Item, wrapLabel: Bool) -> some View {
        VStack(spacing: 3) {
            Text(item.value)
                .font(.system(size: compact ? 14 : 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(item.color)
                .lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let icon = item.icon {
                    Image(systemName: icon).font(.system(size: compact ? 8 : 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(item.label).font(compact ? BridgeFont.micro : BridgeFont.caption)
                    .lineLimit(wrapLabel ? 2 : 1).multilineTextAlignment(.center)
            }
            .foregroundStyle(BridgeTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .help(item.help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.label), \(item.value)")
        .accessibilityHint(item.help ?? "")
    }
}

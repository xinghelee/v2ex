import CryptoKit
import Foundation

/// Persistent store for machine-translated Hacker News text.
///
/// Translating is the slow part of these screens, and the input never changes:
/// a story title or comment is immutable once posted. Re-running it on every
/// visit — and again after every launch — is pure waste.
///
/// Keyed by a digest of the *source* text rather than by item id. Ids get
/// reused across HN's item space in ways we don't control, and keying on the
/// text means an edited comment simply misses instead of showing the old
/// translation under new words.
@MainActor
final class HNTranslationCache {
    static let shared = HNTranslationCache()

    /// Comments run long; this is a few MB at worst, which is well under what
    /// the topic cache already keeps.
    private let maxEntries = 3_000

    private var entries: [String: String] = [:]
    /// Insertion order, oldest first — enough to prune without a real LRU.
    private var order: [String] = []
    private var isDirty = false

    private let file = DiskStore.url(for: "hn-translations.json")

    private struct Payload: Codable {
        var entries: [String: String]
        var order: [String]
    }

    private init() {
        if let payload = DiskStore.load(Payload.self, from: file) {
            entries = payload.entries
            order = payload.order
        }
    }

    func translation(for source: String) -> String? {
        entries[Self.key(source)]
    }

    /// Pre-fills what is already known so only the misses reach the translator.
    func lookup(_ pieces: [(id: Int, text: String)]) -> [Int: String] {
        var found: [Int: String] = [:]
        for piece in pieces {
            if let hit = translation(for: piece.text) { found[piece.id] = hit }
        }
        return found
    }

    func insert(_ translated: String, for source: String) {
        let key = Self.key(source)
        if entries[key] == nil { order.append(key) }
        entries[key] = translated
        isDirty = true

        guard order.count > maxEntries else { return }
        let excess = order.count - maxEntries
        for stale in order.prefix(excess) { entries.removeValue(forKey: stale) }
        order.removeFirst(excess)
    }

    /// Written once per batch rather than per entry — a 30-title screen would
    /// otherwise rewrite the whole file thirty times.
    func save() {
        guard isDirty else { return }
        isDirty = false
        DiskStore.save(Payload(entries: entries, order: order), to: file)
    }

    func clear() {
        entries = [:]
        order = []
        isDirty = true
        save()
    }

    var count: Int { entries.count }

    private static func key(_ source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

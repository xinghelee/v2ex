import Foundation
import Security
import SwiftUI

// MARK: - Token (Keychain)

/// Personal Access Token for API 2.0. Kept in the keychain, not UserDefaults.
@MainActor
final class TokenStore: ObservableObject {
    @Published private(set) var token: String = ""

    private let service = "com.vibe.v2ex.pat"
    private let account = "default"

    var hasToken: Bool { !token.isEmpty }

    init() {
        token = read() ?? ""
    }

    func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        token = trimmed
        delete()
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func clear() {
        token = ""
        delete()
    }

    private func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Followed nodes

@MainActor
final class FollowedNodesStore: ObservableObject {
    @Published private(set) var names: [String] = []

    private let key = "followedNodes"
    /// 本地取消关注的节点（含删掉的默认种子），同步时从网页收藏里排除——
    /// 否则 app 里删掉的下一次自动同步又会被拉回来。
    private let removedKey = "followedNodesRemovedFromSync"
    private var removedFromSync: Set<String> = []
    /// Seeded so a fresh install has a meaningful 关注 tab, matching the design.
    private let defaults = ["programmer", "create", "apple", "coffee", "autistic"]

    init() {
        if let stored = UserDefaults.standard.stringArray(forKey: key) {
            names = stored
        } else {
            names = defaults
            persist()
        }
        removedFromSync = Set(UserDefaults.standard.stringArray(forKey: removedKey) ?? [])
    }

    func isFollowing(_ name: String) -> Bool { names.contains(name) }

    func toggle(_ name: String) {
        if let index = names.firstIndex(of: name) {
            names.remove(at: index)
            removedFromSync.insert(name)
        } else {
            names.append(name)
            removedFromSync.remove(name)
        }
        persist()
    }

    func remove(_ name: String) {
        names.removeAll { $0 == name }
        removedFromSync.insert(name)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        names.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(names, forKey: key)
        UserDefaults.standard.set(Array(removedFromSync), forKey: removedKey)
    }

    /// 拉取网页「我收藏的节点」并合并：远程（网页收藏）按顺序在前，本地独有
    /// （app 内添加、网页没收藏）保留在末尾。未登录或抓取失败静默跳过。
    func syncFromRemote(cookie: String) async {
        guard !cookie.isEmpty else { return }
        guard let remote = try? await V2EXClient.shared.favoriteNodes(cookie: cookie),
              !remote.isEmpty else { return }
        let incoming = remote.filter { !removedFromSync.contains($0) }
        let merged = incoming + names.filter { !incoming.contains($0) }
        var seen = Set<String>()
        names = merged.filter { seen.insert($0).inserted }
        persist()
    }
}

// MARK: - Read state

/// Topic IDs already opened, so 已读的话题变灰 can work.
@MainActor
final class ReadStateStore: ObservableObject {
    @Published private(set) var readIDs: Set<Int> = []
    /// Reply index to restore when 记住阅读进度 is on.
    private(set) var positions: [Int: Int] = [:]

    private let readKey = "readTopicIDs"
    private let positionKey = "readingPositions"
    private var positionWriteTask: Task<Void, Never>?

    init() {
        readIDs = Set(UserDefaults.standard.array(forKey: readKey) as? [Int] ?? [])
        let stored = UserDefaults.standard.dictionary(forKey: positionKey) as? [String: Int] ?? [:]
        positions = stored.reduce(into: [:]) { result, pair in
            if let key = Int(pair.key) { result[key] = pair.value }
        }
    }

    func isRead(_ id: Int) -> Bool { readIDs.contains(id) }

    func markRead(_ id: Int) {
        guard !readIDs.contains(id) else { return }
        readIDs.insert(id)
        // Cap the history so the default store stays small.
        if readIDs.count > 2_000 { readIDs = Set(readIDs.suffix(1_500)) }
        UserDefaults.standard.set(Array(readIDs), forKey: readKey)
    }

    func rememberPosition(_ floor: Int, for topicID: Int) {
        guard positions[topicID] != floor else { return }
        positions[topicID] = floor
        positionWriteTask?.cancel()
        positionWriteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.persistPositions()
        }
    }

    private func persistPositions() {
        let encoded = positions.reduce(into: [String: Int]()) { $0[String($1.key)] = $1.value }
        UserDefaults.standard.set(encoded, forKey: positionKey)
    }

    func position(for topicID: Int) -> Int? { positions[topicID] }
}

// MARK: - Favourites

@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var topics: [V2Topic] = []

    private let file = DiskStore.url(for: "favorites.json")

    init() {
        topics = DiskStore.load([V2Topic].self, from: file) ?? []
    }

    func contains(_ id: Int) -> Bool { topics.contains { $0.id == id } }

    func toggle(_ topic: V2Topic) {
        if let index = topics.firstIndex(where: { $0.id == topic.id }) {
            topics.remove(at: index)
        } else {
            topics.insert(topic, at: 0)
        }
        DiskStore.save(topics, to: file)
    }

    /// 拉取 V2EX 网页收藏并合并进本地（登录态）。本地已有的保留，
    /// 新出现的远程收藏插到最前；未登录或失败时静默跳过。
    func syncFromRemote(cookie: String, maxPages: Int = 10) async {
        guard !cookie.isEmpty else { return }
        guard let remote = try? await V2EXClient.shared.favoriteTopics(
            cookie: cookie,
            maxPages: maxPages
        ) else { return }
        let existing = Set(topics.map(\.id))
        let fresh = remote.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }
        topics.insert(contentsOf: fresh, at: 0)
        DiskStore.save(topics, to: file)
    }
}

// MARK: - 浏览历史

/// 读过的话题，按最近浏览排序，保留 30 天。
///
/// 与 ReadStateStore 的区别：那个只记「这条读过没」用来置灰，是一堆 id；
/// 这里存完整话题以便离线也能把列表画出来，代价是条数要设上限。
final class HistoryStore: ObservableObject {
    struct Entry: Codable, Identifiable {
        let topic: V2Topic
        let viewedAt: Date
        var id: Int { topic.id }
    }

    /// 超过这个天数的记录在每次启动和每次写入时被丢弃。
    static let retentionDays = 30
    /// 上限存在的理由是每条都带完整话题体，无限增长会让启动时的解码变慢。
    private let maxCount = 500

    @Published private(set) var entries: [Entry] = []

    private let file = DiskStore.url(for: "history.json")

    init() {
        entries = Self.pruned(DiskStore.load([Entry].self, from: file) ?? [], limit: maxCount)
    }

    /// 重复浏览同一话题只更新时间并移到最前，不留多条。
    func record(_ topic: V2Topic) {
        var next = entries.filter { $0.topic.id != topic.id }
        next.insert(Entry(topic: topic, viewedAt: Date()), at: 0)
        entries = Self.pruned(next, limit: maxCount)
        persist()
    }

    func remove(id: Int) {
        entries.removeAll { $0.topic.id == id }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        DiskStore.save(entries, to: file)
    }

    private static func pruned(_ list: [Entry], limit: Int) -> [Entry] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        return Array(
            list.filter { $0.viewedAt > cutoff }
                .sorted { $0.viewedAt > $1.viewedAt }
                .prefix(limit)
        )
    }
}

// MARK: - Topic detail cache

/// Automatic stale-while-revalidate cache for topic detail screens. This is
/// separate from OfflineStore: opening a topic should make the next visit
/// instant without adding it to the user's explicit offline-reading list.
@MainActor
final class TopicDetailCacheStore: ObservableObject {
    struct Snapshot: Codable {
        let topic: V2Topic
        let replies: [V2Reply]
        let appends: [TopicAppend]
        let topicViews: Int?
        let savedAt: Date
    }

    private let directory = DiskStore.cacheDirectory(named: "TopicDetails")
    private let maxDiskEntryCount = 50
    private let maxDiskByteSize = 32 * 1_024 * 1_024
    private let maxMemoryEntryCount = 12

    @Published private(set) var byteSize: Int = 0
    private var memory: [Int: Snapshot] = [:]
    private var memoryOrder: [Int] = []

    init() {
        reloadDiskUsage()
    }

    func snapshot(for id: Int) -> Snapshot? {
        if let cached = memory[id] {
            remember(cached, for: id)
            return cached
        }

        let file = fileURL(for: id)
        guard let cached = DiskStore.load(Snapshot.self, from: file) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        remember(cached, for: id)
        return cached
    }

    func save(
        topic: V2Topic,
        replies: [V2Reply],
        appends: [TopicAppend],
        topicViews: Int?
    ) {
        let snapshot = Snapshot(
            topic: topic,
            replies: replies,
            appends: appends,
            topicViews: topicViews,
            savedAt: Date()
        )
        remember(snapshot, for: topic.id)
        DiskStore.save(snapshot, to: fileURL(for: topic.id))
        pruneDiskCache()
        reloadDiskUsage()
    }

    func clearAll() {
        memory.removeAll()
        memoryOrder.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reloadDiskUsage()
    }

    func reloadDiskUsage() {
        byteSize = DiskStore.byteSize(of: directory)
    }

    private func fileURL(for id: Int) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private func remember(_ snapshot: Snapshot, for id: Int) {
        memory[id] = snapshot
        memoryOrder.removeAll { $0 == id }
        memoryOrder.append(id)
        while memoryOrder.count > maxMemoryEntryCount {
            memory.removeValue(forKey: memoryOrder.removeFirst())
        }
    }

    private func pruneDiskCache() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        )) ?? []

        var files = urls.compactMap { url -> (url: URL, size: Int, modified: Date)? in
            guard url.pathExtension == "json" else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
        files.sort { $0.modified < $1.modified }
        var totalSize = files.reduce(0) { $0 + $1.size }

        while files.count > 1,
              files.count > maxDiskEntryCount || totalSize > maxDiskByteSize {
            let oldest = files.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url)
            totalSize -= oldest.size
        }
    }
}

// MARK: - Offline

/// "稍后读 / 离线" — topic body plus replies written to disk so a saved topic
/// opens with no network at all.
@MainActor
final class OfflineStore: ObservableObject {
    struct SavedTopic: Codable, Identifiable {
        let topic: V2Topic
        let replies: [V2Reply]
        let savedAt: Date
        /// `nil` means a bundle written by an older app version and is treated
        /// as a user-saved item so automatic pruning can never remove it.
        let automatic: Bool?
        var id: Int { topic.id }
        var isAutomatic: Bool { automatic == true }
    }

    @Published private(set) var bundles: [SavedTopic] = []
    @Published private(set) var byteSize: Int = 0

    private let directory = DiskStore.directory(named: "Offline")

    init() {
        reload()
    }

    func isOffline(_ id: Int) -> Bool { bundles.contains { $0.id == id } }

    func bundle(for id: Int) -> SavedTopic? { bundles.first { $0.id == id } }

    func save(topic: V2Topic, replies: [V2Reply], automatic: Bool = false) {
        let wasSavedManually = bundle(for: topic.id).map { !$0.isAutomatic } ?? false
        let saved = SavedTopic(
            topic: topic,
            replies: replies,
            savedAt: Date(),
            automatic: automatic && !wasSavedManually
        )
        DiskStore.save(saved, to: directory.appendingPathComponent("\(topic.id).json"))
        reload()
    }

    func needsAutomaticRefresh(for topic: V2Topic) -> Bool {
        guard let saved = bundle(for: topic.id) else { return true }
        return saved.topic.replies < topic.replies || saved.replies.count < topic.replies
    }

    func pruneAutomatic(keeping limit: Int) {
        let expired = bundles
            .filter(\.isAutomatic)
            .sorted { $0.savedAt > $1.savedAt }
            .dropFirst(limit)
        guard !expired.isEmpty else { return }
        for bundle in expired {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(bundle.id).json")
            )
        }
        reload()
    }

    func remove(id: Int) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
        reload()
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: directory)
        reload()
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    private func reload() {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []

        var loaded: [SavedTopic] = []
        for file in files where file.pathExtension == "json" {
            if let saved = DiskStore.load(SavedTopic.self, from: file) { loaded.append(saved) }
        }
        bundles = loaded.sorted { $0.savedAt > $1.savedAt }
        byteSize = DiskStore.byteSize(of: directory)
    }
}

// MARK: - Recent searches

@MainActor
final class RecentSearchStore: ObservableObject {
    @Published private(set) var queries: [String] = []
    private let key = "recentSearches"

    init() {
        queries = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        queries.insert(trimmed, at: 0)
        queries = Array(queries.prefix(12))
        UserDefaults.standard.set(queries, forKey: key)
    }

    func remove(_ query: String) {
        queries.removeAll { $0 == query }
        UserDefaults.standard.set(queries, forKey: key)
    }

    func clear() {
        queries = []
        UserDefaults.standard.set(queries, forKey: key)
    }
}

// MARK: - Compose draft

@MainActor
final class DraftStore: ObservableObject {
    struct Draft: Codable, Identifiable {
        var id: UUID
        var nodeName: String
        var nodeTitle: String
        var title: String
        var body: String
        var savedAt: Date
    }

    private struct Container: Codable {
        var drafts: [Draft]
        var activeID: UUID
    }

    private struct LegacyDraft: Codable {
        var nodeName: String
        var nodeTitle: String
        var title: String
        var body: String
        var savedAt: Date
    }

    @Published private(set) var drafts: [Draft]
    @Published private(set) var activeID: UUID

    private let file = DiskStore.url(for: "drafts.json")
    private let legacyFile = DiskStore.url(for: "draft.json")
    private var saveTask: Task<Void, Never>?

    init() {
        if let saved = DiskStore.load(Container.self, from: file), !saved.drafts.isEmpty {
            drafts = saved.drafts
            activeID = saved.drafts.contains { $0.id == saved.activeID }
                ? saved.activeID
                : saved.drafts[0].id
        } else if let legacy = DiskStore.load(LegacyDraft.self, from: legacyFile) {
            let migrated = Draft(
                id: UUID(),
                nodeName: legacy.nodeName,
                nodeTitle: legacy.nodeTitle,
                title: legacy.title,
                body: legacy.body,
                savedAt: legacy.savedAt
            )
            drafts = [migrated]
            activeID = migrated.id
            persist()
        } else {
            let initial = Self.emptyDraft()
            drafts = [initial]
            activeID = initial.id
        }
    }

    var draft: Draft {
        get { drafts.first(where: { $0.id == activeID }) ?? drafts[0] }
        set {
            var updated = newValue
            updated.savedAt = Date()
            if let index = drafts.firstIndex(where: { $0.id == activeID }) {
                drafts[index] = updated
            } else {
                drafts.append(updated)
                activeID = updated.id
            }
            scheduleSave()
        }
    }

    func save() {
        saveTask?.cancel()
        persist()
    }

    @discardableResult
    func createDraft() -> UUID {
        if isEmpty { return activeID }
        let created = Self.emptyDraft()
        drafts.append(created)
        activeID = created.id
        persist()
        return created.id
    }

    func select(_ id: UUID) {
        guard drafts.contains(where: { $0.id == id }) else { return }
        activeID = id
        persist()
    }

    func delete(_ id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts.remove(at: index)
        if drafts.isEmpty {
            let replacement = Self.emptyDraft()
            drafts = [replacement]
            activeID = replacement.id
        } else if activeID == id {
            activeID = drafts[min(index, drafts.count - 1)].id
        }
        persist()
    }

    func title(for draft: Draft) -> String {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "未命名草稿" : title
    }

    private static func emptyDraft() -> Draft {
        Draft(
            id: UUID(),
            nodeName: "create",
            nodeTitle: "分享创造",
            title: "",
            body: "",
            savedAt: Date()
        )
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        DiskStore.save(Container(drafts: drafts, activeID: activeID), to: file)
    }

    var savedAtText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: draft.savedAt)
    }

    var isEmpty: Bool {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Reply drafts

@MainActor
final class ReplyDraftStore: ObservableObject {
    @Published private var values: [Int: String]

    private let file = DiskStore.url(for: "reply-drafts.json")
    private var saveTask: Task<Void, Never>?

    init() {
        values = DiskStore.load([Int: String].self, from: file) ?? [:]
    }

    func text(for topicID: Int) -> String {
        values[topicID] ?? ""
    }

    func update(_ text: String, for topicID: Int) {
        if text.isEmpty {
            values.removeValue(forKey: topicID)
        } else {
            values[topicID] = text
        }
        scheduleSave()
    }

    func clear(topicID: Int) {
        guard values.removeValue(forKey: topicID) != nil else { return }
        saveTask?.cancel()
        persist()
    }

    func save() {
        saveTask?.cancel()
        persist()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        DiskStore.save(values, to: file)
    }
}

// MARK: - Disk helpers

enum DiskStore {
    static func directory(named name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(for file: String) -> URL {
        directory(named: "V2EXData").appendingPathComponent(file)
    }

    static func cacheDirectory(named name: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func byteSize(of directory: URL) -> Int {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
        ]
        guard let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
        }
        return total
    }
}

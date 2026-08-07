import Foundation
import Network

@MainActor
final class AutoOfflineCoordinator: ObservableObject {
    private let maximumNodeCount = 6
    private let maximumTopicsPerRun = 12
    private let maximumStoredTopics = 24
    private let minimumRunInterval: TimeInterval = 30 * 60
    private let lastRunKey = "autoOfflineLastSuccessfulRun"

    private var isRunning = false

    func sync(
        followedNodes: [String],
        token: String,
        settings: AppSettings,
        offline: OfflineStore,
        force: Bool = false
    ) async {
        guard settings.autoOfflineFollowedNodes,
              !followedNodes.isEmpty,
              !isRunning else { return }

        if !force,
           let lastRun = UserDefaults.standard.object(forKey: lastRunKey) as? Date,
           Date().timeIntervalSince(lastRun) < minimumRunInterval {
            return
        }

        guard await NetworkGate.allowsDownload(wiFiOnly: settings.offlineOnWiFiOnly) else {
            return
        }

        isRunning = true
        defer { isRunning = false }

        var merged: [V2Topic] = []
        for node in followedNodes.prefix(maximumNodeCount) {
            guard !Task.isCancelled else { return }
            if let topics = try? await V2EXClient.shared.topics(inNode: node) {
                merged.append(contentsOf: topics)
            }
        }

        var seen = Set<Int>()
        let newest = merged
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.lastTouched ?? $0.created ?? 0) > ($1.lastTouched ?? $1.created ?? 0) }
            .prefix(maximumTopicsPerRun)

        for topic in newest where offline.needsAutomaticRefresh(for: topic) {
            guard !Task.isCancelled else { return }
            do {
                let fullTopic = try await V2EXClient.shared.topic(id: topic.id, token: token)
                let replies = fullTopic.replies == 0
                    ? []
                    : try await V2EXClient.shared.replies(topicID: topic.id)
                offline.save(topic: fullTopic, replies: replies, automatic: true)
            } catch {
                // A failed topic must not prevent the remaining followed topics
                // from being available offline.
                continue
            }
        }

        offline.pruneAutomatic(keeping: maximumStoredTopics)
        UserDefaults.standard.set(Date(), forKey: lastRunKey)
    }
}

private enum NetworkGate {
    static func allowsDownload(wiFiOnly: Bool) async -> Bool {
        guard wiFiOnly else { return true }

        return await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            let queue = DispatchQueue(label: "com.vibe.v2ex.offline-network-gate")
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: queue)
        }
    }
}

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Keeps local favourites and recent reading history discoverable from
/// Spotlight and Siri. The index contains previews already stored on-device;
/// no network request is performed while indexing.
actor SpotlightIndexer {
    static let shared = SpotlightIndexer()

    private let domain = "com.vibe.v2ex.topics"

    func replace(with topics: [V2Topic]) async {
        let unique = Dictionary(topics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values
            .sorted { $0.id > $1.id }
        let items = unique.map(searchableItem)
        let index = CSSearchableIndex.default()

        await withCheckedContinuation { continuation in
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
                continuation.resume()
            }
        }

        guard !items.isEmpty else { return }
        await withCheckedContinuation { continuation in
            index.indexSearchableItems(items) { _ in
                continuation.resume()
            }
        }
    }

    private func searchableItem(for topic: V2Topic) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = topic.title
        attributes.contentDescription = topic.excerpt.isEmpty
            ? "\(topic.authorName) · \(topic.nodeTitle)"
            : String(topic.excerpt.prefix(240))
        attributes.displayName = topic.title
        attributes.contentURL = URL(string: "v2ex://topic/\(topic.id)")
        attributes.keywords = [topic.nodeTitle, topic.node?.name, topic.authorName]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }

        return CSSearchableItem(
            uniqueIdentifier: "topic-\(topic.id)",
            domainIdentifier: domain,
            attributeSet: attributes
        )
    }
}

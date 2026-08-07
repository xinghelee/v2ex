import SwiftUI
import Translation

/// Batch on-device translation for the Hacker News screens.
///
/// Apple's framework will not translate until the language pair is downloaded,
/// and it signals that by throwing rather than by asking. The first attempt
/// therefore has to catch the failure, call `prepareTranslation()` — which is
/// what actually raises the system download prompt — and try once more.
enum HNTranslator {
    static let source = Locale.Language(identifier: "en")
    static let target = Locale.Language(identifier: "zh-Hans")

    static func configuration() -> TranslationSession.Configuration {
        // A fresh instance each time: SwiftUI re-runs `translationTask` on
        // identity change, so reusing one would silently do nothing.
        TranslationSession.Configuration(source: source, target: target)
    }

    enum Failure: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let detail): return detail
            }
        }
    }

    /// Returns `id -> 译文`. Throws only when translation is genuinely
    /// unavailable, so the caller can say so instead of showing stale English
    /// under a button that claims to be translating.
    static func translate(
        _ pieces: [(id: Int, text: String)],
        using session: TranslationSession
    ) async throws -> [Int: String] {
        // Anything already translated comes straight back; only the misses cost
        // anything. A revisited story is then free, including across launches.
        var result = await HNTranslationCache.shared.lookup(pieces)
        let pending = pieces.filter { result[$0.id] == nil }
        guard !pending.isEmpty else { return result }

        let requests = pending.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id))
        }
        let sourceByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0.text) })

        // Ask first rather than failing and guessing why. `.supported` means the
        // pair exists but its model is not on the device yet, and
        // `prepareTranslation()` is what raises the system download prompt.
        HNClient.log("translate: \(pending.count) 条待翻译，查可用性…")
        let status = await LanguageAvailability().status(from: source, to: target)
        HNClient.log("translate: 可用性=\(String(describing: status))")
        switch status {
        case .unsupported:
            throw Failure.unavailable("这台设备不支持「英文 → 简体中文」的端上翻译。")
        case .supported:
            do {
                HNClient.log("translate: prepareTranslation 开始（可能弹下载提示）")
                try await session.prepareTranslation()
                HNClient.log("translate: prepareTranslation 返回")
            } catch {
                throw Failure.unavailable("需要先下载翻译模型，但没能开始：\(error.localizedDescription)")
            }
        default:
            break
        }

        let fresh: [Int: String]
        do {
            HNClient.log("translate: 提交 \(requests.count) 条")
            fresh = try await run(requests, on: session)
            HNClient.log("translate: 返回 \(fresh.count) 条")
        } catch {
            throw Failure.unavailable("翻译失败：\(error.localizedDescription)")
        }

        await MainActor.run {
            for (id, translated) in fresh {
                guard let source = sourceByID[id] else { continue }
                HNTranslationCache.shared.insert(translated, for: source)
            }
            // 整批写一次盘，而不是每条都写。
            HNTranslationCache.shared.save()
        }
        result.merge(fresh) { _, new in new }
        return result
    }

    /// Same work, but handing each translation over the moment it lands.
    ///
    /// `translations(from:)` only returns once the whole batch is done, so a
    /// long thread showed nothing at all until the last comment finished. The
    /// total time is unchanged; what changes is that the reader can start
    /// reading. Order the pieces so the title comes first and it flips to
    /// Chinese almost immediately.
    static func stream(
        _ pieces: [(id: Int, text: String)],
        using session: TranslationSession,
        onResult: @escaping @MainActor (Int, String) -> Void
    ) async throws {
        guard !pieces.isEmpty else { return }

        var pending: [(id: Int, text: String)] = []
        for piece in pieces {
            if let hit = await HNTranslationCache.shared.translation(for: piece.text) {
                await onResult(piece.id, hit)
            } else {
                pending.append(piece)
            }
        }
        guard !pending.isEmpty else { return }

        let sourceByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0.text) })
        let requests = pending.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id))
        }

        // Attempt first, diagnose second.
        //
        // The earlier version gated on `LanguageAvailability` and refused when
        // it said `.unsupported`. That check is conservative — treating it as a
        // gate means refusing to even try in cases that would have worked. Now
        // it only supplies the explanation once the attempt has actually failed.
        do {
            try await consume(requests, sourceByID: sourceByID, on: session, onResult: onResult)
        } catch {
            let status = await LanguageAvailability().status(from: source, to: target)
            HNClient.log("translate: 首次失败，可用性=\(String(describing: status))")
            switch status {
            case .unsupported:
                throw Failure.unavailable("这台设备不支持「英文 → 简体中文」的端上翻译。")
            case .supported:
                // Model not downloaded yet — this is the call that asks for it.
                do {
                    try await session.prepareTranslation()
                    try await consume(requests, sourceByID: sourceByID, on: session, onResult: onResult)
                } catch {
                    throw Failure.unavailable("需要下载「英文 → 简体中文」翻译模型：\(error.localizedDescription)")
                }
            default:
                throw Failure.unavailable("翻译失败：\(error.localizedDescription)")
            }
        }
        await MainActor.run { HNTranslationCache.shared.save() }
    }

    private static func consume(
        _ requests: [TranslationSession.Request],
        sourceByID: [Int: String],
        on session: TranslationSession,
        onResult: @escaping @MainActor (Int, String) -> Void
    ) async throws {
        for try await response in session.translate(batch: requests) {
            guard let key = response.clientIdentifier, let id = Int(key) else { continue }
            let text = response.targetText
            await MainActor.run {
                onResult(id, text)
                if let source = sourceByID[id] {
                    HNTranslationCache.shared.insert(text, for: source)
                }
            }
        }
    }

    private static func run(
        _ requests: [TranslationSession.Request],
        on session: TranslationSession
    ) async throws -> [Int: String] {
        var result: [Int: String] = [:]
        for response in try await session.translations(from: requests) {
            guard let key = response.clientIdentifier, let id = Int(key) else { continue }
            result[id] = response.targetText
        }
        return result
    }
}

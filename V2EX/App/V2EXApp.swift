import SwiftUI

@main
struct V2EXApp: App {
    @State private var showLaunchAnimation = true
    @StateObject private var settings = AppSettings()
    @StateObject private var token = TokenStore()
    @StateObject private var session = V2EXSessionStore()
    @StateObject private var aiConfiguration = AIConfigurationStore()
    @StateObject private var followed = FollowedNodesStore()
    @StateObject private var readState = ReadStateStore()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var topicCache = TopicDetailCacheStore()
    @StateObject private var offline = OfflineStore()
    @StateObject private var recentSearches = RecentSearchStore()
    @StateObject private var radar = RadarStore()
    @StateObject private var moderation = ModerationStore()
    @StateObject private var agreement = AgreementStore()
    @StateObject private var drafts = DraftStore()
    @StateObject private var replyDrafts = ReplyDraftStore()
    @StateObject private var history = HistoryStore()

    var body: some Scene {
        WindowGroup {
            RootView(isLaunching: $showLaunchAnimation)
                .environmentObject(settings)
                .environmentObject(token)
                .environmentObject(session)
                .environmentObject(aiConfiguration)
                .environmentObject(followed)
                .environmentObject(readState)
                .environmentObject(favorites)
                .environmentObject(topicCache)
                .environmentObject(offline)
                .environmentObject(recentSearches)
                .environmentObject(radar)
                .environmentObject(moderation)
                .environmentObject(agreement)
                .environmentObject(drafts)
                .environmentObject(replyDrafts)
                .environmentObject(history)
                .preferredColorScheme(settings.theme.colorScheme)
                .tint(Theme.accent)
                .overlay {
                    if showLaunchAnimation {
                        LaunchAnimationView {
                            showLaunchAnimation = false
                        }
                        .ignoresSafeArea()
                    }
                }
                .task(id: spotlightSignature) {
                    await SpotlightIndexer.shared.replace(with: spotlightTopics)
                }
        }
    }

    private var spotlightTopics: [V2Topic] {
        let stored = favorites.topics + history.entries.map(\.topic)
        return moderation.filter(stored)
    }

    private var spotlightSignature: String {
        spotlightTopics.map {
            "\($0.id):\($0.lastTouched ?? $0.created ?? 0)"
        }
        .joined(separator: ",")
    }
}

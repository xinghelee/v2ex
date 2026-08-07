import SwiftUI

struct ReadingSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var offline: OfflineStore
    @EnvironmentObject private var topicCache: TopicDetailCacheStore

    @State private var showClearConfirm = false
    @State private var networkCacheByteSize = 0

    private var cacheByteSize: Int {
        offline.byteSize
            + topicCache.byteSize
            + networkCacheByteSize
            + URLCache.shared.currentMemoryUsage
            + URLCache.shared.currentDiskUsage
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(cacheByteSize), countStyle: .file)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageIntro(text: "控制阅读进度如何记忆，以及哪些内容自动下载留在本机。")
                readingSection
                offlineSection
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("阅读与离线")
        .navigationBarTitleDisplayMode(.large)
        // 设置是一条向下钻的支线，底部标签栏留着只会诱人半路跳走。
        .toolbar(.hidden, for: .tabBar)
        .task { await reloadCacheUsage() }
        .confirmationDialog("清空缓存？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空 \(formattedCacheSize)", role: .destructive) {
                clearCache()
            }
            Button("取消", role: .cancel) { }
        }
    }

    private var readingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "阅读")
            CardSection {
                toggleRow(title: "记住阅读进度", isOn: $settings.rememberReadingPosition)
                RowSeparator()
                toggleRow(title: "标记已读的话题变灰", isOn: $settings.dimReadTopics)
            }
        }
    }

    private var offlineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "离线与缓存")
            CardSection {
                toggleRow(
                    title: "自动离线关注节点",
                    subtitle: settings.offlineOnWiFiOnly ? "仅 Wi-Fi 下载" : "使用任意网络下载",
                    isOn: $settings.autoOfflineFollowedNodes
                )
                RowSeparator()
                toggleRow(title: "仅在 Wi-Fi 下载", isOn: $settings.offlineOnWiFiOnly)
                RowSeparator()
                Button {
                    showClearConfirm = true
                } label: {
                    HStack {
                        Text("清空缓存")
                            .font(.system(size: 17))
                            .kerning(-0.43)
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Text(formattedCacheSize)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: Theme.Metric.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggleRow(title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 17))
                    .kerning(-0.43)
                    .foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Theme.Metric.rowHeight)
    }

    private func reloadCacheUsage() async {
        topicCache.reloadDiskUsage()
        networkCacheByteSize = await V2EXClient.shared.cacheUsage()
    }

    private func clearCache() {
        offline.clearAll()
        topicCache.clearAll()
        URLCache.shared.removeAllCachedResponses()
        RemoteImageMemoryCache.clear()
        networkCacheByteSize = 0
        Task { await V2EXClient.shared.clearCache() }
    }
}

import Foundation
import StoreKit
import SwiftUI

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var displayVersion: String { "\(version) (\(build))" }
}

struct GitHubRelease: Decodable, Identifiable {
    let id: Int
    let tagName: String
    let body: String?

    var displayVersion: String {
        tagName.first?.lowercased() == "v" ? String(tagName.dropFirst()) : tagName
    }

    var highlights: [String] {
        (body ?? "").components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
            return String(trimmed.dropFirst(2))
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case body
    }
}

private struct AppVersion: Comparable {
    let components: [Int]

    init?(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first?.lowercased() == "v" {
            normalized.removeFirst()
        }
        normalized = String(normalized.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? "")

        let components = normalized.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard !components.isEmpty,
              components.count == normalized.split(separator: ".", omittingEmptySubsequences: false).count else {
            return nil
        }
        self.components = components
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var availableRelease: GitHubRelease?

    private static let releaseURL = URL(string: "https://api.github.com/repos/xinghelee/v2ex/releases/latest")!
    private static let reminderVersionKey = "updateReminderVersion"
    private static let reminderDateKey = "updateReminderDate"
    private static let reminderInterval: TimeInterval = 24 * 60 * 60

    private var hasChecked = false
    private var presentedRelease: GitHubRelease?

    func checkForUpdate() async {
        guard !hasChecked else { return }
        hasChecked = true

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-showUpdateSheet") {
            present(Self.previewRelease)
            return
        }
        #endif

        guard await Self.isTestFlightBuild else { return }

        do {
            var request = URLRequest(url: Self.releaseURL)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadRevalidatingCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else { return }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let current = AppVersion(AppInfo.version),
                  let latest = AppVersion(release.tagName),
                  current < latest,
                  !isSnoozed(release) else { return }
            present(release)
        } catch {
            // Update checks should never interrupt normal app startup.
        }
    }

    func snoozePresentedRelease() {
        guard let presentedRelease else { return }
        UserDefaults.standard.set(presentedRelease.displayVersion, forKey: Self.reminderVersionKey)
        UserDefaults.standard.set(Date(), forKey: Self.reminderDateKey)
        self.presentedRelease = nil
    }

    private func present(_ release: GitHubRelease) {
        presentedRelease = release
        availableRelease = release
    }

    private func isSnoozed(_ release: GitHubRelease) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.reminderVersionKey) == release.displayVersion,
              let date = defaults.object(forKey: Self.reminderDateKey) as? Date else {
            return false
        }
        return Date().timeIntervalSince(date) < Self.reminderInterval
    }

    private static var isTestFlightBuild: Bool {
        get async {
            do {
                guard case .verified(let transaction) = try await AppTransaction.shared else { return false }
                return transaction.environment == .sandbox
            } catch {
                return false
            }
        }
    }

    #if DEBUG
    private static let previewRelease = GitHubRelease(
        id: -1,
        tagName: "v1.1.0",
        body: """
        ## 主要更新

        - 优化首页与话题详情的浏览体验
        - 提升图片预览的加载速度
        - 修复已知问题并改善稳定性
        """
    )
    #endif
}

struct TestFlightUpdateSheet: View {
    let release: GitHubRelease

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let testFlightURL = URL(string: "https://testflight.apple.com/join/jUBsFk9u")!

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 72, height: 72)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(spacing: 7) {
                        Text("有新的测试版本")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.center)
                        Text("V2EX \(release.displayVersion) 已可通过 TestFlight 安装")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                    }

                    if !release.highlights.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("本次更新")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.ink)

                            ForEach(Array(release.highlights.prefix(5).enumerated()), id: \.offset) { _, highlight in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.top, 2)
                                    Text(highlight)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.body)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 20)
            }

            VStack(spacing: 10) {
                Button {
                    openURL(testFlightURL)
                    dismiss()
                } label: {
                    Label("在 TestFlight 中更新", systemImage: "arrow.down.app.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button("稍后提醒") { dismiss() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .frame(height: 34)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(Theme.canvas)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.canvas)
    }
}

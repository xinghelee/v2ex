import SwiftUI

/// 「我的 → 内容与屏蔽」。把屏蔽名单、被举报隐藏的内容、以及举报记录
/// 摆在同一页 —— 用户按下举报之后，唯一能反悔的地方就是这里。
struct ModerationSettingsView: View {
    @EnvironmentObject private var moderation: ModerationStore
    @Environment(\.openURL) private var openURL

    @State private var newKeyword = ""
    @State private var newUsername = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageIntro(text: "屏蔽与举报都只影响这台设备上你看到的内容。举报会同时发给开发者，由开发者在 24 小时内核实并上报 V2EX 站方。")

                keywordSection
                usernameSection
                hiddenSection
                reportSection

                Text("屏蔽和举报的记录只存在本机，不会随账号同步。")
                    .font(Type.meta(12))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.faint)
                    .padding(.horizontal, Theme.Metric.headerPadding)
            }
            .readableColumn()
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("内容与屏蔽")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: 屏蔽名单

    private var keywordSection: some View {
        listSection(
            header: "屏蔽的关键词",
            placeholder: "添加要屏蔽的关键词",
            text: $newKeyword,
            items: moderation.keywords,
            onAdd: { moderation.addKeyword($0) },
            onRemove: { moderation.removeKeyword($0) }
        )
    }

    private var usernameSection: some View {
        listSection(
            header: "屏蔽的用户",
            placeholder: "添加要屏蔽的用户名",
            text: $newUsername,
            items: moderation.usernames,
            onAdd: { moderation.block(username: $0) },
            onRemove: { moderation.unblock(username: $0) }
        )
    }

    // MARK: 被举报隐藏的内容

    @ViewBuilder
    private var hiddenSection: some View {
        let hiddenTopics = moderation.hiddenTopicIDs.sorted(by: >)
        let hiddenReplies = moderation.hiddenReplyIDs.sorted(by: >)
        if !hiddenTopics.isEmpty || !hiddenReplies.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GroupHeader(title: "已隐藏的内容")
                CardSection {
                    ForEach(Array(hiddenTopics.enumerated()), id: \.element) { index, id in
                        hiddenRow(title: "话题 #\(id)", isFirst: index == 0) {
                            moderation.unhideTopic(id)
                        }
                    }
                    ForEach(Array(hiddenReplies.enumerated()), id: \.element) { index, id in
                        hiddenRow(
                            title: "回复 #\(id)",
                            isFirst: index == 0 && hiddenTopics.isEmpty
                        ) {
                            moderation.unhideReply(id)
                        }
                    }
                }
            }
        }
    }

    private func hiddenRow(title: String, isFirst: Bool, onRestore: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isFirst { RowSeparator(leadingInset: Theme.Metric.cardPadding) }
            HStack {
                Text(title)
                    .font(Type.body(16))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button("恢复显示") {
                    withAnimation(.snappy) { onRestore() }
                }
                .font(Type.meta(13))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Metric.cardPadding)
            .frame(minHeight: 48)
        }
    }

    // MARK: 举报记录

    @ViewBuilder
    private var reportSection: some View {
        if !moderation.reports.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GroupHeader(title: "举报记录")
                CardSection {
                    ForEach(Array(moderation.reports.prefix(30).enumerated()), id: \.element.id) { index, report in
                        if index > 0 { RowSeparator(leadingInset: Theme.Metric.cardPadding) }
                        reportRow(report)
                    }
                }
                if moderation.pendingReportCount > 0 {
                    Text("有 \(moderation.pendingReportCount) 条举报还没送达开发者，App 会自动重试。急需处理可以点这条记录用邮件直接发送。")
                        .font(Type.meta(12))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, Theme.Metric.headerPadding)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func reportRow(_ report: ContentReport) -> some View {
        Button {
            guard let url = ReportService.mailtoURL(for: report) else { return }
            openURL(url)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: report.kind == .block ? "nosign" : "flag")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.summary)
                        .font(Type.body(15))
                        .foregroundStyle(Theme.ink)
                    Text("\(report.kind == .block ? "已屏蔽" : report.reason.title) · \(RelativeTime.string(from: report.createdAt))")
                        .font(Type.meta(12))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Text(report.isDelivered ? "已送达" : "待发送")
                    .font(Type.label(11))
                    .foregroundStyle(report.isDelivered ? Theme.muted : Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        report.isDelivered ? AnyShapeStyle(Theme.inset) : AnyShapeStyle(Theme.accentSoft),
                        in: Capsule()
                    )
                    .padding(.top, 1)
            }
            .padding(.horizontal, Theme.Metric.cardPadding)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 复用的名单编辑区

    private func listSection(
        header: String,
        placeholder: String,
        text: Binding<String>,
        items: [String],
        onAdd: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: header)
            CardSection {
                HStack(spacing: 10) {
                    TextField(placeholder, text: text)
                        .font(.system(size: 16))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            onAdd(text.wrappedValue)
                            text.wrappedValue = ""
                        }
                    Button {
                        onAdd(text.wrappedValue)
                        text.wrappedValue = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 54)

                ForEach(items, id: \.self) { item in
                    RowSeparator()
                    HStack {
                        Text(item)
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Button {
                            withAnimation(.snappy) { onRemove(item) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.unreadDot)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                }
            }
        }
    }
}

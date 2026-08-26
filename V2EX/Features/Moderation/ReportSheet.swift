import SwiftUI

/// 举报表单。选一个理由、可选补充说明，提交后内容立刻消失。
///
/// 刻意做成必须选理由才能提交：无理由的举报对开发者核实没有帮助，而且
/// Apple 也要看到举报是有内容的动作，而不是一个隐藏按钮。
struct ReportSheet: View {
    let target: ModerationTarget

    @EnvironmentObject private var moderation: ModerationStore
    @Environment(\.dismiss) private var dismiss

    @State private var reason: ReportReason?
    @State private var note = ""
    @State private var alsoBlock = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("举报后，\(target.kindTitle)会立刻从你的 App 里移除，并发送给开发者核实。开发者会在 24 小时内处理确认违规的内容。")
                        .font(Type.body(14))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, Theme.Metric.headerPadding)
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        GroupHeader(title: "举报理由")
                        CardSection {
                            ForEach(Array(ReportReason.allCases.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    reason = item
                                } label: {
                                    HStack(spacing: 12) {
                                        Text(item.title)
                                            .font(Type.body(16))
                                            .foregroundStyle(Theme.ink)
                                        Spacer(minLength: 8)
                                        Image(systemName: reason == item ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 18))
                                            .foregroundStyle(reason == item ? Theme.accent : Theme.faint)
                                    }
                                    .padding(.horizontal, Theme.Metric.cardPadding)
                                    .frame(minHeight: Theme.Metric.rowHeight)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if index < ReportReason.allCases.count - 1 {
                                    RowSeparator(leadingInset: Theme.Metric.cardPadding)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        GroupHeader(title: "补充说明（可选）")
                        CardSection(padding: 14) {
                            TextField("再多说两句，帮助开发者判断…", text: $note, axis: .vertical)
                                .lineLimit(3...6)
                                .font(Type.body(15))
                                .onChange(of: note) { _, value in
                                    // 超出这个长度服务端会拒收，而 outbox 会
                                    // 拿同一份 payload 无限重试 —— 与其让举报
                                    // 静默失败，不如在这里就打住。
                                    if value.count > ReportService.noteLimit {
                                        note = String(value.prefix(ReportService.noteLimit))
                                    }
                                }
                            if note.count > ReportService.noteLimit - 200 {
                                Text("\(note.count) / \(ReportService.noteLimit)")
                                    .font(Type.meta(12))
                                    .foregroundStyle(Theme.muted)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .padding(.top, 4)
                            }
                        }
                    }

                    if !target.author.isEmpty {
                        CardSection {
                            Toggle(isOn: $alsoBlock) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("同时屏蔽 @\(target.author)")
                                        .font(Type.body(16))
                                        .foregroundStyle(Theme.ink)
                                    Text("此人的所有话题和回复都不再出现")
                                        .font(Type.meta(12))
                                        .foregroundStyle(Theme.muted)
                                }
                            }
                            .tint(Theme.accent)
                            .padding(.horizontal, Theme.Metric.cardPadding)
                            .frame(minHeight: Theme.Metric.rowHeight)
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Theme.canvas)
            .navigationTitle("举报\(target.kindTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") { submit() }
                        .fontWeight(.semibold)
                        .disabled(reason == nil)
                }
            }
        }
    }

    private func submit() {
        guard let reason else { return }
        moderation.report(target, reason: reason, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        if alsoBlock, !target.author.isEmpty {
            moderation.block(target)
        }
        dismiss()
    }
}

// MARK: - 内容菜单

/// 话题、回复、用户主页共用的举报/屏蔽菜单项。
///
/// 三处的菜单长得一样，用户在任何一处学会的动作在另外两处都成立 ——
/// 审核员也是这么找的。
struct ModerationMenuItems: View {
    let target: ModerationTarget
    let onReport: (ModerationTarget) -> Void

    @EnvironmentObject private var moderation: ModerationStore

    var body: some View {
        Button {
            onReport(target)
        } label: {
            Label("举报\(target.kindTitle)", systemImage: "flag")
        }

        if !target.author.isEmpty, !moderation.isBlocked(username: target.author) {
            Button(role: .destructive) {
                moderation.block(target)
            } label: {
                Label("屏蔽 @\(target.author)", systemImage: "nosign")
            }
        }
    }
}

import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageIntro(text: "深浅模式、主题色与正文排版，改动即时生效。")
                themeSection
                paletteSection
                bodySection
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas)
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.large)
        // 设置是一条向下钻的支线，底部标签栏留着只会诱人半路跳走。
        .toolbar(.hidden, for: .tabBar)
    }

    // MARK: 主题

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "主题")
            HStack(spacing: 10) {
                ForEach(ThemePreference.allCases) { preference in
                    themeCard(preference)
                }
            }
            .padding(.horizontal, Theme.Metric.screenPadding)
        }
    }

    private func themeCard(_ preference: ThemePreference) -> some View {
        let isSelected = settings.theme == preference
        return Button {
            withAnimation(.snappy) { settings.theme = preference }
        } label: {
            VStack(spacing: 7) {
                preview(for: preference)
                    .frame(height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isSelected ? Theme.accent : Theme.separator,
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
                Text(preference.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.muted)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 主题色

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "主题色")
            HStack(spacing: 10) {
                ForEach(ThemePalette.allCases) { palette in
                    paletteCard(palette)
                }
            }
            .padding(.horizontal, Theme.Metric.screenPadding)
            // 给选中环外扩的那几点留出空间，否则顶边会被裁掉。
            .padding(.vertical, 6)
        }
    }

    private func paletteCard(_ palette: ThemePalette) -> some View {
        let isSelected = settings.palette == palette
        return Button {
            withAnimation(.snappy) { settings.palette = palette }
        } label: {
            VStack(spacing: 10) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [palette.accent, palette.accentDeep],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 46, height: 46)
                    // 极淡的内圈，免得深色模式下暗色块直接融进卡片底。
                    .overlay { Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1) }
                    .overlay {
                        // 选中环外扩一圈、和色块之间留空隙。描在边缘上会被
                        // 渐变本身吃掉，看起来只像边更深了一点。
                        Circle()
                            .strokeBorder(Theme.accent, lineWidth: 2)
                            .padding(-5)
                            .opacity(isSelected ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity)
                Text(palette.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.muted)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func preview(for preference: ThemePreference) -> some View {
        switch preference {
        case .light:
            miniScreen(background: Color(hex: 0xF2F2F7), bar: Color(hex: 0xC7C7CC), card: .white)
        case .dark:
            miniScreen(background: .black, bar: Color(hex: 0x48484A), card: Color(hex: 0x1C1C1E))
        case .system:
            HStack(spacing: 0) {
                Color(hex: 0xF2F2F7)
                Color.black
            }
        }
    }

    private func miniScreen(background: Color, bar: Color, card: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(bar).frame(width: 34, height: 8)
            RoundedRectangle(cornerRadius: 6).fill(card)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
    }

    // MARK: 正文

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "正文")
            CardSection {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("正文字号")
                            .font(.system(size: 17))
                            .kerning(-0.43)
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(Int(settings.bodyFontSize)) pt")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 10) {
                        Text("A").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Slider(value: $settings.bodyFontSize, in: 13...21, step: 1)
                            .tint(Theme.accent)
                        Text("A").font(.system(size: 19)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                RowSeparator()

                picker(title: "行距", selection: $settings.lineSpacing, options: LineSpacingPreference.allCases) {
                    $0.title
                }

                RowSeparator()

                picker(title: "代码块等宽字体", selection: $settings.monoFont, options: MonoFontPreference.allCases) {
                    $0.title
                }

                RowSeparator()

                // Live preview so the sliders above have something to act on.
                VStack(alignment: .leading, spacing: 8) {
                    Text("预览")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                    Text("上周开始强制的：提 MR 之前必须跑一遍内部的 review bot，它给出的 blocking 意见得逐条回复才能进 CI。")
                        .font(settings.bodyFont)
                        .lineSpacing(settings.bodyLineSpacing)
                        .foregroundStyle(Theme.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("$ gitlab-ci review --model internal-v3")
                        .font(settings.codeFont(size: settings.bodyFontSize - 3))
                        .foregroundStyle(Theme.body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    private func picker<Option: Identifiable & Hashable>(
        title: String,
        selection: Binding<Option>,
        options: [Option],
        label: @escaping (Option) -> String
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 17))
                .kerning(-0.43)
                .foregroundStyle(Theme.ink)
            Spacer()
            Menu {
                Picker(title, selection: selection) {
                    ForEach(options) { option in
                        Text(label(option)).tag(option)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(label(selection.wrappedValue))
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                    Chevron()
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Theme.Metric.rowHeight)
    }

}

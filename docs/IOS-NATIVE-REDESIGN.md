# V2EX iOS 原生差异化设计系统

## 产品定位

这不是“把 V2EX 网页装进原生壳”，而是一个帮助用户感知社区活性、理解长讨论、沉淀阅读资产的社区信息工具。

产品表达由三个独有模块组成：

1. **Pulse / 社区脉冲**：基于关注节点、实时活跃、未读与阅读历史，生成一眼可理解的社区状态。
2. **Orbit / 节点轨道**：节点距离代表个人相关性，面积代表实时活跃度，动量代表增长速度。
3. **Threadline / 讨论脉络**：把回复密度、楼主参与、引用关系与未读位置压缩成一条可导航的长帖地图。

## 原生设计边界

- Liquid Glass 只存在于导航和临时交互层：系统标签栏、工具按钮、滚动上下文胶囊、回复输入器。
- 内容层不铺玻璃。话题、回复、节点数据使用实体表面和系统分隔，保证可读性和层级稳定。
- 顶层导航使用系统 `TabView`：脉冲、节点、通知、我的；搜索使用独立的 `.search` role。发布话题属于 toolbar action，不放进标签栏。
- 支持系统深浅模式、增大对比度、减少透明度、动态字体和 Reduce Motion；信号色不能成为唯一状态线索。

## 页面架构

### 首页：社区脉冲

- 首屏不是推荐大卡片，而是由真实数据驱动的社区状态：活跃节点、增长最快的主题、关注范围内的异常活跃。
- 脉冲区域使用 `Canvas` 或 Metal shader 绘制，属于内容可视化，不使用 Liquid Glass。
- 下方保留高密度原生话题列表；左侧 Thread mark 表示近期讨论速度，回复数和颜色同时表达热度。
- 滚动向下时系统标签栏最小化，向上或回到顶部自动恢复。

### 节点：Orbit

- 默认显示与用户相关的节点轨道；距离、面积和动量分别对应相关性、活跃度和增长。
- VoiceOver 不读取空间关系，而提供按相关性排序的等价列表。
- 搜索和完整分类仍保留，Orbit 是发现入口，不替代可预测的信息架构。

### 阅读：Threadline

- 话题列表进入详情使用 `matchedTransitionSource` 和 `.navigationTransition(.zoom)`，保持来源上下文。
- 标题滚出后出现滚动上下文玻璃胶囊，显示节点、缩略标题和阅读进度。
- Threadline 在右缘显示回复密度、楼主楼层、未读断点；选择“观点密度”后可按讨论簇跳转。
- 回复编辑器使用 `GlassEffectContainer`，输入、附件和发送控件只在聚焦时融合成一个玻璃组。

### 通知：行动收件箱

- 默认不是按类型筛选，而是先区分“需要回应”和“仅供知晓”。
- 回复、提及和感谢仍可筛选；状态同时使用符号、文字和颜色。
- 清空未读触发轻量成功触觉，不用全屏庆祝动画。

### 我的：阅读记忆

- 收藏、标注、离线、讨论和关注节点被视为阅读资产，而不是设置菜单。
- 阅读节奏只展示给用户自己；默认本地计算，不上传行为画像。
- 离线资料库可接入 Widget、Spotlight 和 App Intent；下载过程可以使用 Live Activity，完成后自动结束。

## SwiftUI API 映射

| 体验 | SwiftUI / 系统能力 |
| --- | --- |
| 系统浮动标签栏与独立搜索 | `TabView`, `Tab(role: .search)`, `tabBarMinimizeBehavior(.onScrollDown)` |
| 玻璃工具组融合与拆分 | `GlassEffectContainer`, `glassEffectID`, `glassEffectTransition` |
| 行到话题的连续转场 | `matchedTransitionSource`, `navigationTransition(.zoom)` |
| 脉冲随滚动收束 | `visualEffect`, `scrollTransition`, `onScrollGeometryChange` |
| 轻量选择与完成反馈 | `sensoryFeedback(.selection/.success, trigger:)` |
| 底部内容穿透与柔和边缘 | `scrollEdgeEffectStyle(.soft, for: .bottom)` |
| 离线下载状态 | ActivityKit Live Activity、WidgetKit、App Intents |
| 系统检索 | Core Spotlight、`.searchable`、搜索标签角色 |

## 动效规范

- 控件按压：系统 interactive glass，不叠加自定义缩放；只有网页原型用缩放模拟。
- 页面切换：系统 spring，目标 320–420ms；信息淡入延迟不超过 60ms。
- 脉冲循环：6–8s，低振幅，不改变文本位置，不作为必需信息来源。
- Threadline 跳转：滚动 280–360ms，落点后一次 `.selection` 触觉。
- Reduce Motion 开启时：取消雷达扫描、缩放转场改交叉淡化、Threadline 直接跳转。

## App Review 差异化证据

视觉改版不能单独解决 4.3 风险。提交审核时应在 Review Notes 与录屏中明确展示：

- Pulse 如何使用用户关注和阅读状态形成个性化社区概览。
- Threadline 如何帮助用户浏览长讨论、恢复阅读位置和跳转观点簇。
- Orbit 如何提供传统节点目录没有的实时发现方式。
- 离线资料库、Widget、Spotlight、App Intent 和 Live Activity 如何利用 iOS 平台能力。

这些功能必须真实可用，不能只存在于截图或审核描述中。

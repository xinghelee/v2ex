# v2Explore

> Way to Explore

面向个人使用的 V2EX iOS 客户端。使用 SwiftUI 构建，采用 iOS 26 原生 Liquid Glass 组件，数据来自 V2EX API、网页会话和 sov2ex 搜索。

## 下载

- **TestFlight 公测**：[testflight.apple.com/join/jUBsFk9u](https://testflight.apple.com/join/jUBsFk9u)
- **Android 版**：[xinghelee/v2ex-android](https://github.com/xinghelee/v2ex-android)，APK 见其 [Releases](https://github.com/xinghelee/v2ex-android/releases/latest)（Android 8.0+）

## 截图

<p align="center">
  <img src="docs/screenshots/home-hd.png" alt="V2EX 首页" width="24%"/>
  <img src="docs/screenshots/topic-hd.png" alt="V2EX 话题详情" width="24%"/>
  <img src="docs/screenshots/nodes-hd.png" alt="V2EX 节点目录" width="24%"/>
  <img src="docs/screenshots/profile-hd.png" alt="V2EX 个人页面" width="24%"/>
</p>

## 功能

- **首页**：全部、最热、关注和快捷节点，多分类横向切换并分别记忆滚动位置
- **话题**：正文、代码、引用、列表与图片渲染，楼层回复、只看楼主、阅读数、收藏、离线与长帖分页
- **节点**：完整节点搜索与分类目录，可编辑、排序和增删首页快捷节点，支持节点话题排序与分页
- **账户**：账号密码、验证码、两步验证或网页登录；会话仅保存在本机 Keychain
- **通知**：Personal Access Token 驱动，回复、@、感谢分类筛选，支持未读状态和删除
- **搜索**：sov2ex 全文索引（话题/回复/用户/节点），命中高亮
- **个人**：个人资料、话题统计、网页收藏同步、稍后读、我的话题与回复、关键词和用户屏蔽
- **写作**：多份 Markdown 草稿、节点选择和格式工具栏，新话题与逐帖回复草稿均自动保存
- **阅读与外观**：五套主题配色、明暗模式、正文字号、行距和等宽字体可调，可记忆阅读进度并自动离线关注节点
- **系统智能**：iOS 27 设备端讨论摘要；不可用时可由用户配置 OpenAI 兼容 API，另有 Siri/快捷指令与 Spotlight 集成
- **交互**：原生悬浮标签栏随滚动收起，列表下拉刷新，点击页面空白处收起键盘

## 技术要点

| 模块 | 说明 |
| --- | --- |
| API 1.0 | 公开接口：话题、回复、节点、成员、全部节点 |
| API 2.0 | Personal Access Token：通知、个人资料、长帖分页、删除通知 |
| 网页会话 | App 内回复、收藏同步、关注节点同步；Cookie 只存储在 Keychain |
| sov2ex | 社区全文索引，V2EX 无官方搜索接口 |
| iOS 26 | 最低系统版本；原生 Tab、`safeAreaBar`、`glassEffect`、边缘滚动效果与标签栏自动收起 |
| iOS 27 | Foundation Models 设备端摘要、App Intents/Siri 深链与 Spotlight 语义入口（渐进增强） |
| AI 回退 | 用户可选配置 DeepSeek、硅基流动、OpenAI 或任意 OpenAI 兼容 API；Key 仅存 Keychain |
| 渲染 | 自研轻量 HTML 解析（段落/行内/图片提取），替代 NSAttributedString 方案 |
| 存储 | Keychain（Token）、UserDefaults（设置）、磁盘缓存（离线包） |
| 内容治理 | 首启条款闸门、举报与屏蔽，命中内容即时且持久地从全部列表移除 |

一些工程决策：

- **下拉刷新**：统一封装系统 `refreshable`，只在当前可见列表响应，避免多个分页容器同时争抢手势
- **键盘收起**：窗口级点击捕获不拦截按钮、链接和滚动手势，所有页面点击空白处均可结束编辑
- **图片渲染**：`AsyncImage` 必须显式 frame，否则按原图尺寸布局被裁剪；帖子图片由解析器从 `<p>` 内提取为独立 block
- **通知头像**：API 2.0 通知的 `member` 只带 `username`，用 v1 接口按用户补齐头像（内存缓存防刷新丢失）
- **阅读数**：API 不提供 views 字段，从话题页抓取解析（`N views` / `N 次点击`），失败静默隐藏
- **列表性能**：话题列表用 `LazyVStack` 惰性构建，避免分页累积后 AsyncImage 下载风暴

## 构建

```bash
# 修改 project.yml 后重新生成工程（需要 XcodeGen）
xcodegen generate

# 1.2.0 的 iOS 27 能力需要 Xcode 27；部署目标仍为 iOS 26
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

# 模拟器
xcodebuild -project V2EX.xcodeproj -scheme V2EX \
  -destination 'generic/platform=iOS Simulator' build

# 真机（需签名配置）
open V2EX.xcodeproj   # Signing & Capabilities 里选 Team 后 Cmd+R
```

## 项目结构

```
V2EX/
├── App/              # 入口、Tab 导航、路由
├── DesignSystem/     # 主题配色、组件、话题视图
├── Features/         # 首页/节点/通知/话题/搜索/个人/设置
├── Models/           # Codable 模型
├── Networking/       # V2EX API、网页会话、HTML 解析
├── Storage/          # 设置、Keychain、收藏与离线缓存
├── V2EX.icon/        # Icon Composer 应用图标
└── IconSources/      # 图标源图层
```

## 说明

- 浏览话题无需登录；通知、个人资料和长帖分页需要 Personal Access Token
- App 内回复、收藏和关注节点同步需要 V2EX 网页会话；密码不会保存
- V2EX 没有开放发帖 API，草稿可自动保存后到网页发布
- API 频率上限 600 次/小时/IP

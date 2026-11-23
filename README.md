# Sticky Notes for macOS

用 Swift / SwiftUI 写的原生 macOS 便笺应用，色板和交互对齐微软 Sticky Notes（Windows 应用与 Outlook 网页便笺）。支持浮窗便笺、富文本、微软账号登录后与 Microsoft Graph 双向同步，以及严格的按账号本地数据隔离与安全加固。

![macOS](https://img.shields.io/badge/macOS-14.0+-blue?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-5-blue?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green)

> 本项目基于 [**MartinPirate/sticky-notes-macos**](https://github.com/MartinPirate/sticky-notes-macos) 衍生改进，原作者为 **MartinPirate**（遵循 MIT 许可证）。在此基础上补充了中英双语、微软 Graph 同步、按账号隔离与安全/稳定性系统性加固；当前 README 已与仓库最新源码保持同步。

## 功能概览

- **浮窗便笺**：每条便笺独立无边框置顶浮窗，记住窗口位置和尺寸；列表窗口关闭后应用继续驻留，点击 Dock 图标可恢复（含最小化还原）。
- **富文本与编辑器**：支持粗体 / 斜体 / 下划线 / 删除线、项目符号与待办勾选（切换前缀保留行内样式、隐藏文本与行内图片）、隐藏/揭示敏感文本（列表标题/预览及搜索自动打码防泄密）、受限安全粘贴与图片自动缩放（上限 1600px），全格式操作接入 `UndoManager` 支持 `⌘Z`。
- **七色色板**：黄、绿、粉、紫、蓝、灰、炭笔（与官方应用同一选择顺序；已废弃的本地「橙」自动映射为炭笔，炭笔在浅色模式下具备高对比度前景色）。
- **便笺列表与搜索**：集中浏览、按未隐藏正文过滤搜索和管理；仅在确认微软账号身份后展示对应作用域的便笺。
- **听写与录音**：支持系统语音识别听写（支持时优先启用本地离线识别 `requiresOnDeviceRecognition`）及麦克风录音附件（单次上限 10 分钟；录音、听写与回放互斥）。
- **自动识别链接与白名单校验**：正文与导入 HTML 中的链接经 `SafeURLPolicy` 校验，仅允许 `http`、`https`、`mailto` 协议。
- **微软账号登录**：通过 `ASWebAuthenticationSession` 与 PKCE OAuth 登录 Outlook / Microsoft 365，`OAuth` 与 `/me` 请求默认使用独立 `URLSessionConfiguration.ephemeral`（不落盘缓存、不留持久 Cookie）；令牌存在登录钥匙串（Prepare-Write-Commit 原子写与代次清理）；取消登录会完整恢复登录前会话；支持「设置 → 微软账号」中编辑或恢复默认 OAuth 配置。
- **云端同步与恢复**：通过 Microsoft Graph 读写 Notes 文件夹中的 `IPM.StickyNote`；分页拉取校验域名/端口/`/v1.0/` 路径与防环检测（上限 100 页）；统一经 `SyncEngine.requestDeletion` 执行删除守卫；提供「待核对与恢复」界面管理未知新建/失败删除记录；颜色通过 `_Note` JSON 与 `0x8B00` / `0x1080` 在本应用间同步，但微软公开 Graph 接口目前未开放背景色字段且不与 Outlook 网页版 `NotesFabric` 互通颜色（详见 [`docs/COLOR_SYNC_LIMITATION.md`](docs/COLOR_SYNC_LIMITATION.md)）。
- **账号隔离与本地安全**：作用域以 Graph `/me.id` 为准；非沙盒全新安装使用应用专属目录 `~/Library/Application Support/com.shenanigans.sticky-notes/default.store` 并在首次打开前创建完整副本安全备份（含 `-wal`/`-shm` 与外部存储目录），遇 TCC 拒权或库损坏直接停启并弹窗提示以防数据分裂；本地导出文件设 `0600` 权限，录音临时文件存放在 `0700` 私有子目录并在启动时清理。
- **跟随活动窗口**：可在设置中开启「跟随活动应用窗口」，通过辅助功能（AX）在后台线程读取当前前台窗口位置并防抖调整浮窗（支持多显示器）。
- **网页原色保护**：只有用户在本地选过颜色时，上传才会写 `_Note` / `0x8B00` / `0x1080`；仅改文字的待上传或失败重试不会覆盖网页原色。
- **浅色 / 深色模式与中英界面**：每色提供浅色 / 深色正文与工具条配色，完整适配 `en` 与 `zh-Hans`。

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `⌘ N` | 新建便笺 |
| `⌘ B` | 粗体 |
| `⌘ I` | 斜体 |
| `⌘ U` | 下划线 |
| `⌘ ⇧ X` | 删除线 |
| `⌘ ⇧ L` | 项目符号列表 |
| `⌘ ⇧ S` | 立即与微软便笺同步 |
| `⌘ W` | 关闭当前窗口 |

## 下载与构建产物说明

- **GitHub Releases 下载地址**：[https://github.com/StartNight/sticky-notes-macos/releases](https://github.com/StartNight/sticky-notes-macos/releases)
- **当前构建产物**（`v1.0.1`）：
  - `StickyNotes-macOS-Universal.zip`（约 **1.7 MB**；解压后为 `Sticky Notes.app`，Universal 双架构 `arm64` + `x86_64`，解压体积约 **3.9 MB**）
  - `StickyNotes-macOS-Universal.zip.sha256`（SHA-256 校验文件，可用 `shasum -a 256 -c StickyNotes-macOS-Universal.zip.sha256` 校验；哈希值：`1cc0dc52648d00b127a36f871908bd14bda32d2df6c910a586f18a6b1f305391`）
- **构建与安全属性**：
  - 使用 Release 配置编译，已开启 Hardened Runtime（`flags=0x10000(runtime)`）、`DEAD_CODE_STRIPPING` 与符号剥离，已确认不含 `com.apple.security.get-task-allow`。
  - 最低系统要求：`macOS 14.0 (Sonoma)+`。
  - **签名说明**：当前产物使用本机自签名证书签名，**未经过 Apple Developer 公证（Notarization）**。
- **安装与首次打开说明**：
  1. 下载并解压 `StickyNotes-macOS-Universal.zip`，将 `Sticky Notes.app` 拖入 `/Applications`。
  2. 首次打开如遇 macOS Gatekeeper 提示「无法验证开发者」或「已损坏」，请在「系统设置 → 隐私与安全性」点击「仍要打开」，或执行以下命令移除隔离属性：

```bash
xattr -dr com.apple.quarantine "/Applications/Sticky Notes.app"
```

## 环境要求

- macOS 14.0（Sonoma）或更高
- Xcode 15.0 或更高
- 如需调整工程结构：[XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.35 或更高（`brew install xcodegen`）

## 构建与测试

工程文件 `StickyNotes.xcodeproj` 由仓库根目录的 `project.yml` 生成并纳入版本库。只改 Swift 源码时直接打开工程即可；若增删源文件或修改构建配置，先重新生成工程：

```bash
xcodegen generate
open StickyNotes.xcodeproj          # 或在 Xcode 中 Cmd+R 运行
```

命令行编译 Debug / Release 应用（Release 已开启 `ENABLE_HARDENED_RUNTIME: YES`、`DEAD_CODE_STRIPPING`、符号剥离与 `dwarf-with-dsym`，保持 `arm64 + x86_64` Universal 构建，产物约 3.9 MB）：

```bash
xcodebuild -project StickyNotes.xcodeproj -scheme StickyNotes -destination 'platform=macOS' build
xcodebuild -project StickyNotes.xcodeproj -scheme StickyNotes -configuration Release -destination 'platform=macOS' clean build
```

运行无宿主单元测试（共 **289** 个用例，**不启动宿主 App**，不会打开你的真实数据库、钥匙串或剪贴板，也不会向 Graph 发真实请求）：

```bash
xcodebuild test -project StickyNotes.xcodeproj -scheme StickyNotesTests -destination "platform=macOS"
```

`StickyNotesTests` 将所需生产源码直接编入测试包，采用内存 / 临时 SwiftData、隔离的 `UserDefaults` suite、`FakeKeychainBackend`、`MockURLProtocol` 及完整剪贴板快照还原。请勿把测试 scheme 改为「宿主启动真正的 Sticky Notes.app」。

可选的颜色同步诊断日志默认关闭，排查色差时可由使用者手动开启（应用本身不会写入该键）：

```bash
defaults write com.shenanigans.sticky-notes ColorDiagnosticsEnabled -bool YES
# 重启 App 后同步，查看日志：
log show --last 10m --info --predicate 'subsystem == "com.shenanigans.sticky-notes" AND category == "color-sync"'
```

日志中的对象 ID 为 SHA-256 前 6 位十六进制，不包含正文、标题、token 或账号信息。

## 本地自签名

`scripts/sign-local.sh` 用本机自签身份给编好的 Release `.app` 重新签名（仅包含公开身份名称与指纹，不含私钥或口令；支持 `IDENTITY_NAME` / `IDENTITY_SHA1` 环境变量覆盖）。脚本先由内向外签名嵌套二进制与 `Contents/MacOS` 同级辅助程序（签名阶段不使用 `--deep`），对主包开启 Hardened Runtime（`--options runtime`）并移除 `com.apple.security.get-task-allow`，最后执行 `codesign --verify --deep --strict` 严格校验：

```bash
scripts/sign-local.sh "/path/to/Sticky Notes.app"
```

首次安装或更换新签名构建时，系统可能弹出钥匙串访问提示，请由使用者本人在系统弹窗中选择。

## 源码职责

按目录分组，对应当前仓库中的 `StickyNotes/**/*.swift`、`Tests/**/*.swift`、`scripts/*.sh`、`project.yml` 和 `docs/`。

### 应用入口（`StickyNotes/App`）

| 文件 | 职责 |
|---|---|
| `StickyNotesApp.swift` | 应用入口：探测容器库 TCC 权限（防 `EPERM`/`EACCES` 分裂）、打开独立路径 SwiftData 容器与只读安全备份、启动采纳提示协调器与活动窗口追踪；`AppDelegate` 负责启动清理遗留临时录音、列表关窗保活与 Dock 最小化还原；提供菜单命令（含 `⌘⇧X` / `⌘⇧L` / `⌘⇧S`）。 |

### 模型（`StickyNotes/Models`）

| 文件 | 职责 |
|---|---|
| `StickyNote.swift` | SwiftData 便笺模型（正文、富文本、颜色、窗口几何、同步/恢复状态等）、按内容版本 `@Transient` 缓存的 `redactedPlainText`、`hasUnresolvedRecoveryState` 与损坏日志只读防覆写保护；以及内存索引的真 LRU `ColorEditLedger`。 |
| `NoteColor.swift` | 官方七色枚举、浅深色正文/工具条色值、官方十六进制色码，以及把已废弃 `orange` 映射为炭笔的兼容读取。 |
| `AccountScope.swift` | 严格账号可见范围（`ActiveScope.resolve` 在认证中置 `.blocked`）、排除隐藏文本的搜索查询（`NoteScopeQuery`）、云端痕迹判定与窗口开闭计划。 |

### 服务（`StickyNotes/Services`）

| 文件 | 职责 |
|---|---|
| `AuthManager.swift` | 微软 PKCE OAuth 登录/登出、专用 `URLSessionConfiguration.ephemeral` 会话、回调 scheme/host/path 与 CSRF 校验、OAuth 配置注入与重置、`/me.id` 复核、取消登录回滚会话、刷新单飞 / 时钟回拨保护与指数退避、`presentationAnchor` 选窗。 |
| `SyncEngine.swift` | 与 Microsoft Graph 双向拉取/上传/冲突保全/替换清理/恢复关联；`@odata.nextLink` 安全校验与防环、`graphItemURL` 路径校验、`requestDeletion` 统一删除守卫、拉取/上传时间线门槛、401 刷新令牌传递与可停启周期定时器。 |
| `SyncRecoveryTypes.swift` | 同步恢复类型：远端对象种类、核对动作、向后兼容可解码的审计条目 `RecoveryAuditEntry`、已核验候选与导出数据结构。 |
| `NoteConverter.swift` | 纯 Swift 离线安全 HTML 解析器 `OfflineHTMLParser`（替代 WebKit）、HTML 与 `NSAttributedString` 双向转换（内联 `data:image/png`、安全链接与隐藏文本、跳过系统动态语义色）、`_Note` / `0x8B00` / `0x1080` 颜色映射与静态日期/诊断助手。 |
| `AccountIsolationService.swift` | 账号隔离服务：首次登录采纳协调器 `AdoptionPromptCoordinator`（按便笺 ID 记录单次跳过）、无账号认领与遗留隔离区复制（含数据库保存失败回滚）、单编码安全导出器 `LocalExporter`（过滤非有限浮点坐标）与 `StoreSafetyBackup`。 |
| `WindowManager.swift` | 跟踪已打开的可见便笺窗口，自动清理陈旧 `openNoteIDs` 并提供置前、关窗与窗口位置读取。 |
| `ActiveWindowTracker.swift` | 通过辅助功能（AX）在后台线程（带超时、多屏安全换算与防抖重定位）追踪当前前台应用窗口，在开启跟随时自动把浮窗便笺排列在其下方。 |
| `TextEditorProxy.swift` | 驱动 `NSTextView` 的 `@MainActor` 格式化代理：基于 `UndoManager` 的属性编辑、仅替换行首前缀的列表/待办切换、`longestEffectiveRange` 全段揭示隐藏文本、混合选区统一格式化与 `NotePasteSupport` 菜单路由。 |
| `AudioRecorder.swift` | 麦克风录音与播放控制器：`0700` 私有临时录音目录与启动清理、10 分钟录制上限、代理身份核验与计时器清理、SHA-256 缓存时长查询与录音/回放互斥。 |
| `SpeechRecognizer.swift` | 系统语音识别控制器：惰性 `AVAudioEngine`、优先本地离线识别 `requiresOnDeviceRecognition`、`activeSessionID` 防过期回调、音频格式守卫与 `os.Logger` 日志。 |

### 工具（`StickyNotes/Utilities`）

| 文件 | 职责 |
|---|---|
| `KeychainHelper.swift` | 登录钥匙串可注入 `Sendable` 后端与并发安全包装：非交互探测、一次性交互说明读取、Prepare-Write-Commit 原子写（含 `errSecDuplicateItem` 重试）及基于 `epoch` 的登出防竞态清理。 |
| `ColorExtensions.swift` | 从十六进制整数构造 SwiftUI `Color` 与 AppKit `NSColor`。 |
| `DateFormatting.swift` | 列表和界面用的日历自然日差异计算、24 小时制适配与未来日期安全格式化。 |
| `DurationFormatting.swift` | 录音时长格式化（安全拦截 `NaN` / `Infinity` / 负数输入）。 |
| `URLDetector.swift` | `SafeURLPolicy` URL Scheme 安全白名单校验（仅放行带有效宿主/目标的 `http`、`https`、`mailto`）。 |

### 列表界面（`StickyNotes/Views/NotesList`）

| 文件 | 职责 |
|---|---|
| `NotesListView.swift` | 便笺列表主窗口：单次计算可见列表与隐藏数据提示、搜索过滤、旋转同步状态动画、登录弹窗错误反馈与统一删除确认。 |
| `NoteCardView.swift` | 单条便笺卡片：单次读取预览缓存、炭笔浅色对比度适配、隐藏无意义待上传角标与带状态保护的右键改色。 |
| `SearchBar.swift` | 带无障碍清除按钮的搜索栏。 |

### 便笺窗口（`StickyNotes/Views/NoteWindow`）

| 文件 | 职责 |
|---|---|
| `NoteWindowView.swift` | 单条浮窗便笺容器：加载/防抖保存/退出即时 flush、`externalSyncVersion` 防自触发覆盖与 IME 保护、录音/听写生命周期与关窗/删笺资源清理、快捷格式化响应。 |
| `NoteToolbarView.swift` | 便笺顶部工具条：富文本格式化按钮、录音/听写状态指示（带输入互斥）、新建/改色/删除菜单。 |
| `NoteTextEditor.swift` | `NSViewRepresentable` 包装可点击 `ClickableTextView`：安全剪贴板过滤粘贴、图片等比缩放、列表延续与安全退出列表、字符范围与字形区间边界校验。 |
| `FormattingBar.swift` | 粗体 / 斜体 / 下划线 / 删除线 / 项目符号 / 待办清单 / 隐藏文本工具栏按钮组。 |
| `ColorPickerMenu.swift` | 七色圆点选择器（含炭笔高对比度勾选标识与唯一无障碍标识）。 |
| `AudioClipView.swift` | 便笺内录音列表与播放/删除控件（从 `AudioRecorder` 缓存读时长，不在视图重绘中构造播放器）。 |

### 共用界面（`StickyNotes/Views/Shared`）

| 文件 | 职责 |
|---|---|
| `SettingsView.swift` | 设置页：默认颜色与旧 `"orange"` 归一化、常规偏好、与全局状态同步的微软账号登录/同步、登录态锁定的 OAuth 配置与恢复默认。 |
| `LocalDataSettingsView.swift` | 「本地数据」管理页：按范围及身份校验导出（文件 `0600` 权限）、无账号便笺认领、隔离区遗留便笺移动/复制（绑定账号与登录代次防止切号误操作）、旧版钥匙串分步清理。 |
| `RecoveryReviewView.swift` | 同步恢复待核对页：网络核验期间锁定列表与输入防竞态、操作前快照确认弹窗、精确关联/删旧/明确重建/放行替换降级与恢复数据导出（`0600` 权限）。 |
| `AdoptionAlertPresenter.swift` | 非侵入式 App 级首次登录采纳弹窗：仅在前台活跃且无其他模态窗时弹出、取消高危回车默认快捷键，展示受限标题截断与错误提示。 |
| `WindowAccessor.swift` | 通过 `NSView.viewDidMoveToWindow()` + `NotificationCenter` 无侵入配置窗口外观、层级与尺寸防抖保存（不劫持 SwiftUI 原生 `window.delegate`），提供列表窗口识别与安全关窗辅助视图。 |

### 单元测试（`Tests`）

测试包共 **289** 个用例，无宿主应用、无真实网络、不触碰宿主数据库、钥匙串或剪贴板。

| 文件 | 职责 |
|---|---|
| `StickyNoteModelTests.swift` | 便笺模型、SwiftData 持久化、安全窗口坐标、`redactedPlainText` 错位防泄露与改色错误态保护。 |
| `NoteColorTests.swift` | 七色枚举、`_Note` / `0x8B00` / `0x1080` 色码映射与可选诊断日志脱敏标签验证。 |
| `NoteConverterTests.swift` | HTML 与富文本离线互转、安全链接/实体单遍解码、`data:image/png`/隐藏文本往返与动态语义色导出处理。 |
| `SyncEngineTests.swift` | 同步状态机、防抖/重试、隔离账本颜色保护、网页原色保护与上传/拉取边界用例。 |
| `SyncLifecycleTests.swift` | 网络屏障下的创建超时锁定、替换清理重启恢复、并发拉取防误删与冲突保全测试。 |
| `SyncJournalPersistenceTests.swift` | 同步/恢复预写日志持久化与损坏 JSON 原始字节只读保护验证。 |
| `RecoveryWorkflowTests.swift` | 恢复核对流程：候选核验、关联快照、明确重建与禁止自动重建降级验证。 |
| `AccountIsolationTests.swift` | 按账号严格隔离可见性、跨账号防泄露、采纳/认领/复制防重、离线导出与 `StoreSafetyBackup` WAL/外部目录备份测试。 |
| `AccountMigrationTests.swift` | 旧版无隔离字段数据库迁移安全性测试。 |
| `AuthManagerTests.swift` | 登录取消会话恢复、`/me.id` 核验与防串号、刷新单飞/冷却/指数退避与登出防竞态（全部使用 `FakeKeychainBackend` 与 `mockSession`）。 |
| `KeychainHelperTests.swift` | 钥匙串助手非交互探测、一次性同意状态机、原子写入重试与代次清理测试。 |
| `LocalizationTests.swift` | `Localizable.xcstrings` 中 `en` / `zh-Hans` 条目完整翻译、占位符匹配、源码无遗漏及零孤立 key 校验。 |
| `NoteEditorPasteTests.swift` | 通过生产路径测试富文本/纯文本粘贴（完整快照并恢复系统剪贴板）。 |
| `TodoAndFormattingTests.swift` | 经 `TextEditorProxy` 驱动真实 `NSTextView` 验证待办/列表保样式、无字号加粗、`UndoManager` 与长段隐藏文本揭示。 |
| `Phase4HardeningTests.swift` | Phase 4 加固回归测试：OAuth CSRF/回调/配置/时钟回拨、Graph `@odata.nextLink` 分页与防环、路径遍历 ID 拦截、LRU 台账、`DateFormatting` / `DurationFormatting`、`WindowManager` 与 `LocalExporter` 测试。 |
| `Support/AuthManagerStub.swift` | 注入给 `SyncEngine` 的认证/令牌与作用域替身。 |
| `Support/FakeKeychainBackend.swift` | 线程安全的纯内存 `KeychainBackend` 模拟实现。 |
| `Support/MockURLProtocol.swift` | 全量加锁的 `URLProtocol` 测试替身，支持请求拦截与网络断点屏障。 |

### 构建与脚本

| 文件 | 职责 |
|---|---|
| `project.yml` | XcodeGen 工程描述：定义启用 Hardened Runtime 与 Release 瘦身的 `StickyNotes` 应用目标，以及无宿主 `StickyNotesTests` 测试目标。 |
| `scripts/sign-local.sh` | 本机自签脚本：支持环境变量覆盖身份，由内向外签名并启用 Hardened Runtime、剥离 `get-task-allow` 并进行严格深度验证。 |

### 文档（`docs`）

| 文件 | 职责 |
|---|---|
| `docs/ACCOUNT_SYNC_SAFETY.md` | 账号切换、隔离、数据库备份与崩溃安全恢复闭环的设计约束、实施记录与验证边界。 |
| `docs/COLOR_SYNC_LIMITATION.md` | 微软公开 Graph API 与 Outlook 网页版（`NotesFabric`）之间便笺背景颜色无法双向同步的排查记录、接口核查结论与颜色枚举对照。 |

## 其他仓库文件

- `StickyNotes/Resources/Localizable.xcstrings`：中英双语本地化词表（`en` / `zh-Hans`）。
- `StickyNotes/StickyNotes.entitlements`：应用权限声明（包含麦克风权限；Release 自签名流程会移除 `get-task-allow`）。
- `StickyNotes.xcodeproj/`：由 `project.yml` 生成并纳入版本管理的 Xcode 工程文件。
- `.gitignore`：忽略构建目录 `build/`、打包目录 `dist/`、`.DS_Store` 等本地产物。

## 致谢与原作者

- **原作者**：**MartinPirate**
- **原始仓库**：[https://github.com/MartinPirate/sticky-notes-macos](https://github.com/MartinPirate/sticky-notes-macos)
- 感谢原作者以简洁清晰的 Swift / SwiftUI 架构发起了这个开源项目。

## 许可证

遵循原项目相同的 [MIT License](https://opensource.org/licenses/MIT)。

## 不会出现在本仓库说明里的内容

请勿在 issue、PR、日志或文档中提交密码、访问/刷新令牌、钥匙串口令或真实账号信息；单元测试与日常开发亦不得读取或修改用户真实正在使用的本地数据库、系统钥匙串及线上便笺数据。

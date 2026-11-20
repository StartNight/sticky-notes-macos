# Sticky Notes for macOS

用 Swift / SwiftUI 写的原生 macOS 便笺应用，色板和交互对齐微软 Sticky Notes（Windows 应用与 Outlook 网页便笺）。支持浮窗便笺、富文本、微软账号登录后与 Graph 双向同步，以及按账号隔离的本地数据。

![macOS](https://img.shields.io/badge/macOS-14.0+-blue?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-5-blue?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green)

> 本 README 按当前源码职责编写，取代 2024-11-04 那版已经过时的英文说明（旧文仍写着已取消的橙色、也没有登录 / 同步 / 账号隔离 / 钥匙串 / 本地签名）。

## 功能概览

- **浮窗便笺**：每条便笺独立无边框窗口，可钉在桌面上；位置和尺寸会记住。
- **富文本**：粗体 / 斜体 / 下划线 / 删除线、项目符号与待办勾选，支持粘贴或拖入图片。
- **七色色板**：黄、绿、粉、紫、蓝、灰、炭笔（与官方应用同一选择顺序；已废弃的本地「橙」会读成炭笔）。
- **便笺列表**：集中浏览、搜索和管理；关闭列表窗口不会退出应用。
- **听写与录音**：系统语音识别听写，麦克风录音附件。
- **自动识别链接**：正文中的 URL 可点击。
- **微软账号登录**：OAuth 登录 Outlook / Microsoft 365，令牌存在登录钥匙串；取消登录会恢复登录前的会话，不会误当成已退出。
- **云端同步**：通过 Microsoft Graph 读写 Notes 文件夹中的 `IPM.StickyNote`；正文、标题与增删可与 Outlook 网页版双向同步。颜色通过 `_Note` JSON 与 `0x8B00` / `0x1080` 在本应用之间同步，但微软公开 Graph 接口目前未开放背景色字段且不与 Outlook 网页版 `NotesFabric` 互通颜色（详见 `docs/COLOR_SYNC_LIMITATION.md`）。
- **账号隔离**：作用域以 Graph `/me.id` 为准。未验证身份前不显示、不同步、不认领、不复制。升级前留下的无主便笺在「设置 → 本地数据」里显式认领或复制，不会自动挂到新账号上。
- **网页原色保护**：只有用户在本地选过颜色时，上传才会写 `_Note` / 0x8B00；仅改文字的待上传或失败重试不会覆盖网页原色。
- **浅色 / 深色模式**：每色有对应的正文和工具条颜色。
- **中英界面**：`en` 与 `zh-Hans` 本地化。

## 环境要求

- macOS 14.0（Sonoma）或更高
- Xcode 15.0 或更高
- 如需改工程结构： [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.35 或更高（`brew install xcodegen`）

## 构建与测试

工程文件 `StickyNotes.xcodeproj` 由仓库根目录的 `project.yml` 生成，并且目前是纳入版本库的。只改 Swift 源码时直接打开工程即可；若增删源文件或改了捆绑设置，先重新生成再编译：

```bash
xcodegen generate
open StickyNotes.xcodeproj          # 或在 Xcode 里 Cmd+R 运行
```

命令行编译应用：

```bash
xcodebuild -project StickyNotes.xcodeproj -scheme StickyNotes -destination 'platform=macOS' build
```

跑单元测试（**没有宿主 App**，不会打开你的真实数据库，也不会向 Graph 发真实请求）：

```bash
xcodebuild test -scheme StickyNotesTests -destination "platform=macOS"
```

`StickyNotesTests` 把需要的生产源码直接编进测试包，用内存 / 临时目录数据库、钥匙串替身和 `MockURLProtocol` 拦截网络。不要把测试 scheme 改成「宿主启动真正的 Sticky Notes.app」——那会碰到真实数据。

可选的颜色同步诊断日志默认关闭。需要排色差时，由使用者自己执行下面这条（应用自己不会写这个键）：

```bash
defaults write com.shenanigans.sticky-notes ColorDiagnosticsEnabled -bool YES
# 重启 App 后再同步；查看：
log show --last 10m --info --predicate 'subsystem == "com.shenanigans.sticky-notes" AND category == "color-sync"'
```

日志里的对象 id 是 SHA-256 前 6 位十六进制，不含正文、标题、token 或账号。

## 本地自签名

`scripts/sign-local.sh` 用本机自签身份给已经编好的 Release `.app` 签名（只含公开的身份名称和证书指纹，不含私钥或口令）。不使用 `--deep`，不动信任设置，也不导出或删除证书。用法：

```bash
scripts/sign-local.sh "/path/to/Sticky Notes.app"
```

首次安装或每次换一份新签名的构建时，系统可能弹出钥匙串授权；请由使用者本人在弹窗上选择。不要把这个脚本改成申请 Apple 证书或改系统钥匙串。

## 源码职责

按目录分组。下面每个列出的源文件都有一句职责，对应仓库里当前的 `StickyNotes/**/*.swift`、`Tests/**/*.swift`、`scripts/*.sh`、`project.yml` 和 `docs/`。

### 应用入口（`StickyNotes/App`）

| 文件 | 职责 |
|---|---|
| `StickyNotesApp.swift` | 应用入口：创建 SwiftData 容器与安全备份、启动采纳提示协调器、提供列表窗口和「新建便笺」等菜单命令；`AppDelegate` 在列表关闭后保持进程、点击 Dock 时重新打开列表。 |

### 模型（`StickyNotes/Models`）

| 文件 | 职责 |
|---|---|
| `StickyNote.swift` | SwiftData 便笺模型（正文、富文本、颜色、窗口几何、同步状态、归属账号、恢复日志等）以及 `ColorEditLedger`（记录用户是否改过颜色、冲突副本是否应搬运云端原色）。 |
| `NoteColor.swift` | 官方七色枚举、深浅色色值、工具条色，以及把已废弃的 `orange` 读成炭笔。 |
| `AccountScope.swift` | 当前可见范围：已验证账号 / 未登录的「无账号便笺」/ 未验证时的空视图；以及所有权判定和窗口开闭计划。 |

### 服务（`StickyNotes/Services`）

| 文件 | 职责 |
|---|---|
| `AuthManager.swift` | 微软 OAuth 登录与登出、会话快照与取消登录时的恢复、启动后用 `/me.id` 复核缓存身份、访问令牌刷新的单飞 / 冷却 / 指数退避。 |
| `SyncEngine.swift` | 与 Microsoft Graph 的拉取、上传、删除、冲突处理和恢复关联；周期性同步；网页原色保护（未改色不写颜色属性）。 |
| `SyncRecoveryTypes.swift` | 同步恢复用的类型：远端对象种类、核对动作、审计条目、已核验候选和导出结构。 |
| `NoteConverter.swift` | HTML 与 `NSAttributedString` 互转，以及 `_Note` / 0x8B00 的颜色编解码；附带可选的颜色同步诊断日志。 |
| `AccountIsolationService.swift` | 账号隔离：首次登录采纳提示、显式认领无账号便笺、旧版遗留便笺的认领 / 复制与防重复台账。 |
| `WindowManager.swift` | 跟踪已打开的便笺窗口，并在重启后按范围恢复位置。 |
| `ActiveWindowTracker.swift` | 跟踪当前键窗口，供菜单里的剪切 / 复制 / 粘贴作用到正确的便笺。 |
| `TextEditorProxy.swift` | 对 `NSTextView` 做格式化、待办勾选和粘贴（不依赖窗口是否是键窗口）。 |
| `AudioRecorder.swift` | 麦克风录音，把音频附件写进便笺。 |
| `SpeechRecognizer.swift` | 系统语音识别，把听写结果写入便笺正文。 |

### 工具（`StickyNotes/Utilities`）

| 文件 | 职责 |
|---|---|
| `KeychainHelper.swift` | 登录钥匙串读写的可注入边界（探测是否需要交互、按会话存取令牌）；生产路径不使用数据保护钥匙串。 |
| `ColorExtensions.swift` | 从十六进制整数构造 SwiftUI / AppKit 颜色。 |
| `DateFormatting.swift` | 列表和界面用的相对 / 本地日期格式。 |
| `DurationFormatting.swift` | 录音时长等时间间隔的显示格式。 |
| `URLDetector.swift` | 从正文里找出 URL，供自动加链接。 |

### 列表界面（`StickyNotes/Views/NotesList`）

| 文件 | 职责 |
|---|---|
| `NotesListView.swift` | 便笺列表主窗口：按当前账号范围展示、搜索、同步状态、打开设置与本地数据。 |
| `NoteCardView.swift` | 单条便笺卡片：颜色、标题、预览和改色入口。 |
| `SearchBar.swift` | 按正文过滤列表的搜索框。 |

### 便笺窗口（`StickyNotes/Views/NoteWindow`）

| 文件 | 职责 |
|---|---|
| `NoteWindowView.swift` | 单条浮窗便笺：加载 / 保存正文、听写、窗口尺寸位置。 |
| `NoteToolbarView.swift` | 便笺顶部工具条：颜色、格式化、菜单。 |
| `NoteTextEditor.swift` | 用 `NSTextView` 承载富文本编辑、列表前缀和点击链接。 |
| `FormattingBar.swift` | 粗体 / 斜体 / 下划线 / 删除线 / 项目符号按钮条。 |
| `ColorPickerMenu.swift` | 七色圆点选择器。 |
| `AudioClipView.swift` | 便笺内的录音播放与删除控件。 |

### 共用界面（`StickyNotes/Views/Shared`）

| 文件 | 职责 |
|---|---|
| `SettingsView.swift` | 设置页：账号登录 / 登出、同步相关说明，并入口到本地数据。 |
| `LocalDataSettingsView.swift` | 「本地数据」：导出、认领无账号便笺、把旧版遗留便笺复制到当前账号（含可能重复的确认）。 |
| `RecoveryReviewView.swift` | 同步恢复待核对页：核验候选、关联或删除，以及导出核对记录。 |
| `AdoptionAlertPresenter.swift` | 不依赖列表窗口的首次登录采纳对话框（Esc / 「暂不」只跳过本次，不会记成永久拒绝）。 |
| `WindowAccessor.swift` | 配置便笺窗口外观与关闭行为，以及列表窗口和按范围关闭窗口的辅助视图。 |

### 单元测试（`Tests`）

测试包无宿主应用、无真实网络、不读真实数据库或钥匙串。

| 文件 | 职责 |
|---|---|
| `StickyNoteModelTests.swift` | 便笺模型与 SwiftData 持久化（标题、颜色、删除等）。 |
| `NoteColorTests.swift` | 七色枚举、色码映射，以及颜色诊断日志的开关 / 打码标签。 |
| `NoteConverterTests.swift` | HTML 与富文本互转。 |
| `SyncEngineTests.swift` | 同步状态机、防抖与重试、颜色属性的上行下行，以及网页原色保护。 |
| `SyncLifecycleTests.swift` | 创建超时、替换清理等同步生命周期，全程用临时库和模拟网络。 |
| `SyncJournalPersistenceTests.swift` | 同步预写日志 / 清理队列在本地的持久化与恢复。 |
| `RecoveryWorkflowTests.swift` | 恢复核对流程：候选核验、关联、禁止自动重建。 |
| `AccountIsolationTests.swift` | 严格按账号隔离的可见性、采纳 / 认领 / 复制、未验证身份的拦截。 |
| `AccountMigrationTests.swift` | 旧版无隔离字段的数据库，能否被当前模型安全打开。 |
| `AuthManagerTests.swift` | 登录取消恢复、`/me.id` 复核、刷新单飞与退避；全部使用替身，不碰真实凭据。 |
| `KeychainHelperTests.swift` | 钥匙串助手的探测与读写，只用内存后端。 |
| `LocalizationTests.swift` | `Localizable.xcstrings` 中 en / zh-Hans 条目完整且已翻译。 |
| `NoteEditorPasteTests.swift` | 通过生产粘贴路径把剪贴板写入 `NSTextView`（不依赖真实键焦点）。 |
| `TodoAndFormattingTests.swift` | 待办清单和格式化，经 `TextEditorProxy` 驱动真实 `NSTextView`。 |
| `Support/AuthManagerStub.swift` | 注入给 `SyncEngine` 的登录 / 令牌替身。 |
| `Support/FakeKeychainBackend.swift` | 纯内存的 SecItem 模型，不调用系统钥匙串。 |
| `Support/MockURLProtocol.swift` | 拦截 `URLSession.shared`，在本地应答本应发给 Graph 的请求。 |

### 构建与脚本

| 文件 | 职责 |
|---|---|
| `project.yml` | XcodeGen 工程描述：应用目标 `StickyNotes` 与无宿主测试目标 `StickyNotesTests` 的源文件、捆绑标识、权限说明和签名设置。 |
| `scripts/sign-local.sh` | 用本机自签身份为已经编好的 Release `.app` 重新签名（公开身份信息，不含密钥）。 |

### 文档（`docs`）

| 文件 | 职责 |
|---|---|
| `docs/ACCOUNT_SYNC_SAFETY.md` | 账号切换与同步的安全约定：本地数据不得悄带到另一账号、不得扩大危险自动恢复，以及相关产品边界说明。 |
| `docs/COLOR_SYNC_LIMITATION.md` | 微软公开 Graph API 与 Outlook 网页版（`NotesFabric`）之间便笺背景颜色无法双向同步的排查记录、接口核查结论与颜色枚举对照。 |

## 其他仓库文件

这些不是上面清单里的「源文件句责」范围，但日常会碰到：

- `StickyNotes/Resources/Localizable.xcstrings`：界面文案（en / zh-Hans）。
- `StickyNotes/StickyNotes.entitlements`：应用权限（钥匙串、沙盒等）。
- `StickyNotes.xcodeproj/`：已跟踪的 Xcode 工程和 scheme；改结构时用 `xcodegen generate` 再生成。
- `.gitignore`：忽略构建产物等。本地的 `TEST_REPORT.md` 和 `dist/` 是测试与打包留下的未跟踪内容，**不要提交**。`dist/` 里若已有测试在用的构建包，也不要覆盖。

## 不会出现在本仓库说明里的内容

请不要在 issue、PR 或文档里写入密码、刷新令牌、钥匙串口令或真实账号。单元测试和开发过程也不要去读、改用户正在使用的数据库、钥匙串或向 Graph 做真实写入。

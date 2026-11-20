# Sticky Notes 颜色同步限制说明（Microsoft Graph vs. Outlook 网页版）

> 记录日期：2026-11-20  
> 适用范围：macOS 客户端（Microsoft Graph 同步）与 Outlook 网页版（`https://outlook.live.com/mail/notes`）

## 结论摘要

- **正文、标题、新建、删除**：Mac 端与 Outlook 网页版可正常双向同步。
- **Mac 本地与 Mac 之间**：便笺背景颜色通过 Microsoft Graph 扩展属性（`_Note` JSON 与 `0x8B00` / `0x1080`）可正常保存与同步。
- **Mac 端与 Outlook 网页版之间的背景颜色**：**目前无法通过微软对外开放的公开 API 实现双向同步**。在 Mac 端通过 Graph 新建的便笺同步到 Outlook 网页版后会显示为灰色（`Gray`），在 Outlook 网页版修改的颜色也不会回写到 Graph。

---

## 根本原因

### 1. 接口体系分离

- **Outlook 网页版（实测版本 `StickyNotes-Web/11.5.11`）** 并不使用公开的 Microsoft Graph API，而是直接调用微软内部的 **Substrate NotesFabric** 服务：
  - `GET / POST / PATCH / DELETE https://substrate.office.com/NotesFabric/api/v2.0/me/notes`
- **第三方应用（本应用）** 只能调用微软公开的 Microsoft Graph API：
  - `/v1.0/me/notes`（权限 `ShortNotes.ReadWrite`）
  - `/v1.0/me/mailFolders/notes/messages`（权限 `Mail.ReadWrite`）

### 2. 微软公开 API 目前未提供 Sticky Notes 背景色字段

截至 2026 年 11 月，核查 Microsoft Learn 官方文档与线上接口返回结果：

- **Microsoft Graph `note` 资源（`v1.0` / `beta`，`/me/notes`）**：
  - 官方全部公开属性仅包含：
    - 可写字段：`body`、`subject`、`categories`
    - 只读字段：`id`、`changeKey`、`bodyPreview`、`createdDateTime`、`lastModifiedDateTime`、`hasAttachments`、`isDeleted`
    - 关系集合：`attachments`、`extensions`、`singleValueExtendedProperties`、`multiValueExtendedProperties`
  - **不包含 `color` 或任何便笺背景颜色字段**。
- **`categories`（`/me/outlook/masterCategories`）**：
  - 属于 Outlook 通用分类标签，不是 Sticky Notes 网页版的背景色字段；网页端改色后 Graph 返回的 `categories` 依然为空 `[]`，且网页端不读取 `categories` 渲染便签底色。
- **OneNote Graph API（`/me/onenote/...`）**：
  - 仅操作 OneNote 笔记本、分区与页面，不包含 Outlook Sticky Notes 便笺。
- **EWS（Exchange Web Services）**：
  - Exchange Online 的 EWS 已从 2026 年 10 月起逐步禁用、并将于 2027 年 4 月 1 日彻底关停，不再作为可用方案。

### 3. 个人 Outlook.com 账号上的双向实测结果

在 2026-11-19 至 2026-11-20 期间，结合真实个人账号的 Graph 日志与 Chrome 浏览器对 `outlook.live.com/mail/notes` 的只读抓包/状态核验，确认两端在颜色层面完全隔离：

1. **网页端 (`NotesFabric`) → Mac (`Graph`)**：
   - 在 Outlook 网页版修改便签颜色并保存后，Graph 侧可以看到更新后的 `changeKey`、`lastModifiedDateTime`、`subject` 与 HTML `body`。
   - 但同一对象的扩展属性仍保持旧值，未同步新颜色：
     - `String {00020329-0000-0000-c000-000000000046} Name _Note`（未更新）
     - `Integer {0006200e-0000-0000-c000-000000000046} Id 0x8b00`（`PidLidNoteColor`，未更新）
     - `Integer 0x1080`（`PidTagIconIndex`，未更新）
     - `categories` 为空、`hasAttachments` 为 `false`、`extensions` 不可用/为空、MIME `/$value` 仅含标准 `text/plain` 与 `text/html`、其余 20 余个候选 `PS_PUBLIC_STRINGS` / `PSETID_Note` 命名属性均无新增数据。

2. **Mac (`Graph`) → 网页端 (`NotesFabric`)**：
   - 分别使用以下三种公开 Graph 写入路径创建或更新测试便签（包含对齐网页端格式的 `blockStyles: {"textDirection": "ltr"}` 与 `styles: []`，并设置不同数值的 `_Note.color` 与 `0x8b00`）：
     - `POST /v1.0/me/mailFolders/notes/messages`（`_Note.color=4`, `0x8b00=2`）
     - `POST /v1.0/me/notes`（`_Note.color=5`, `0x8b00=1`）
     - `POST /v1.0/me/mailFolders/notes/messages` 后紧接 `PATCH /v1.0/me/notes/{id}`（`_Note.color=3`, `0x8b00=0`）
   - 刷新 Outlook 网页版等待 `NotesFabric` 增量同步完成后，所有测试便签在网页端界面与 `notes.sdk` 中**全部显示为灰色（`Gray`，内部枚举 `0`）**，且正文是通过 HTML 转换生成的新文档块（未使用 `_Note.document`）。

### 4. 为什么第三方客户端无法直接调用 `NotesFabric`

- 直接携带 Graph 令牌访问 `https://substrate.office.com/NotesFabric/api/v2.0/me/notes` 或 `https://outlook.live.com/NotesFabric/api/v2.0/me/notes` 返回 `401 Unauthorized`，`WWW-Authenticate` 要求内部受众 `client_id="ec156f81-f23a-47bd-b16f-9fb2c66420f9"`。
- Outlook 网页版个人账号使用的是微软第一方受众（`api://6bc89243-be1c-423a-99ec-b9a45b8b568b/.default`），`StickyNotes-Web` 内置回退配置中的 MSA 作用域为 `https://substrate.office.com/Notes-Internal.ReadWrite`。
- 第三方 Entra ID 客户端向 `/consumers/oauth2/v2.0/token` 申请上述任一作用域均被微软身份平台拒绝：
  - `https://substrate.office.com/Notes-Internal.ReadWrite` → `400 invalid_scope`（`AADSTS70011`：未向该客户端预授权）
  - `https://substrate.office.com/ShortNotes.ReadWrite`、`https://substrate.office.com/.default`、`ec156f81-f23a-47bd-b16f-9fb2c66420f9/.default`、`api://6bc89243-be1c-423a-99ec-b9a45b8b568b/.default` → `400 invalid_scope`（`AADSTS70011`）
- 尝试通过可换取的 `https://outlook.office.com/.default` 令牌访问：
  - `https://outlook.office.com/NotesFabric/api/v2.0/me/notes` → `401`
  - `https://outlook.office.com/api/v2.0/me/notes` 与 `api/beta/me/notes` → `403 ErrorAccessDenied`
- 服务端校验的是微软身份平台签发令牌内的受众与客户端授权声明，单纯修改 HTTP 请求头或 JSON 结构无法通过鉴权；本应用不采用冒用微软第一方客户端 ID 或抓取网页登录会话等非公开/越权方式。

---

## 颜色枚举对照备忘

| 颜色 | Outlook 网页版 `NotesFabric`（`StickyNotes-Web/11.5.11`） | 本应用 Graph `_Note` 编码（`NoteConverter.swift`） | 经典 MAPI `PidLidNoteColor (0x8B00)`（`[MS-OXONOTE]`） |
|---|---|---|---|
| Gray（灰） | `0` | `5` | —（经典 Outlook 无对应色） |
| Yellow（黄） | `1` | `0` | `3` |
| Green（绿） | `2` | `1` | `1` |
| Pink（粉） | `3` | `2` | `2` |
| Purple（紫） | `4` | `3` | — |
| Blue（蓝） | `5` | `4` | `0` |
| Charcoal（炭笔） | `6` | `6` | — |
| White（白） | — | — | `4` |

> 说明：由于实测确认 `NotesFabric` 在个人账号上不会读取 Graph `_Note` 的颜色值，本应用目前维持原有 `_Note` 编码不变，以确保多台 Mac 之间及已有本地缓存颜色不发生错位。

---

## 排查期间已落地的相关代码修复

尽管跨网页版颜色同步受限于微软接口，但本次排查发现并顺手修复了两处底层实现缺陷（提交 `75f9eae`）：

1. **`StickyNotes/Services/NoteConverter.swift` (`substrateDocument(for:)`)**：
   - 将 `blockStyles` 由数组 `[{"textDirection": "ltr"}]` 修正为对象 `{"textDirection": "ltr"}`；
   - 将 `content` / `styles` 中的 `null` 修正为 `[{"text": line, "styles": []}]`，与网页端文档 schema 保持一致。
2. **`StickyNotes/Services/SyncEngine.swift` (`fetchServerColorProperties`)**：
   - 将请求 `$select` 从 `"id"` 改为 `"id,body"`，防止 Exchange 列表视图将 `_Note` JSON 截断为 255 字符。

---

## 后续可能解除限制的条件

仅当出现以下任一变化时，才具备合规实现与网页端颜色双向同步的条件：

1. 微软在公开的 Microsoft Graph `note` API（`/v1.0/me/notes` 或 `/beta/me/notes`）中正式新增便笺背景色字段；
2. 微软在后端打通 Exchange `IPM.StickyNote` 扩展属性（`_Note` / `0x8B00`）与 `NotesFabric` 之间的颜色双向映射；
3. 微软向第三方 Entra ID 应用正式开放 `NotesFabric` 委派权限；
4. 若不需要与 Outlook 网页版互通颜色，而是追求 Apple 多端一致体验，可考虑另行接入 iCloud（CloudKit）等自有/原生同步通道。

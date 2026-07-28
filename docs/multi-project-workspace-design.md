# Hunk 多项目工作区设计

## 1. 目标

Hunk 的多项目工作区面向同时维护前后端、客户端与服务端、主仓库与工具仓库的开发者。

典型场景：

```text
Acme Workspace
├── back/       Git: main
└── front/      Git: develop
```

用户应该能够：

- 把任意文件夹添加到当前窗口，而不是只能替换当前目录或打开新窗口。
- 在同一个文件树中浏览和编辑多个根目录。
- 同时保留不同项目的编辑标签、未保存缓冲、搜索结果和终端。
- 明确知道每一次 Git 操作作用于哪个仓库。
- 分别查看每个仓库的 Changes、History、Branches、Stashes、Tags 和同步状态。
- 在“全部仓库”视图中快速判断哪个项目需要处理，但不把无关 Git 历史伪装成一张图。

本阶段不包含代码折叠。

## 2. 产品原则

### 2.1 工作区是容器，文件夹和 Git 仓库不是同一个概念

一个工作区包含一个或多个 `WorkspaceFolder`。一个文件夹可能：

- 本身就是 Git 仓库。
- 是普通目录。
- 包含一个或多个嵌套 Git 仓库。

因此不能继续用单一的 `repoRoot` 同时表达“工作区”“文件根”和“Git 操作根”。

### 2.2 仓库身份必须跟随内容

文件、diff、提交、比较、终端和异步任务都必须携带稳定的项目或仓库 ID，不能依赖界面上“当前选中的仓库”临时推断。

这保证用户切换 `back`/`front` 后：

- 已打开的标签不会冲突或消失。
- 未保存内容不会串到另一个同名文件。
- 延迟返回的 Git 任务不会污染另一个项目。
- 提交、重置、丢弃等操作不会作用到错误仓库。

### 2.3 聚合视图只聚合判断，不合并 Git 语义

不同仓库的提交没有共同 DAG，不能画成一张连续泳道图。

“全部仓库”可以聚合：

- 未提交变更数量。
- ahead/behind。
- 当前分支。
- 最近提交。
- 是否正在 rebase 或存在冲突。

但 Commit、Stage、Push、Reset、Rebase 等操作必须始终属于一个明确仓库。

## 3. 信息架构

### 3.1 文件侧边栏

多个根目录始终作为文件树的一级节点，不再通过“整个文件夹 / 当前仓库”切换来替换整棵树。

```text
FILES

▾ back
    cmd
    internal
    go.mod

▾ front
    src
    package.json
    vite.config.ts

────────────────────────
＋ Add Folder
```

交互规则：

- 单根工作区可以隐藏根节点，保持当前 Hunk 的简洁体验。
- 两个及以上根目录时始终显示根节点。
- 点击文件会把它所属的文件夹设为 `activeFolderID`，供新终端等文件操作使用。
- 普通打开文件不自动改变 Source Control 当前仓库，避免侧边栏在浏览文件时突然跳动。
- 只有“查看更改”“查看文件历史”等明确的 Git 导航才自动切换 `activeRepositoryID`。
- 根目录支持拖拽排序。
- 根目录右键菜单提供：
  - 在 Finder 中显示
  - 复制路径
  - 在新窗口打开
  - 重命名工作区显示名
  - 从工作区移除
- 移除文件夹前，如果其中存在未保存缓冲或正在运行的 Git 操作，必须确认。

### 3.2 拖入文件夹

窗口已有内容时，拖入目录显示：

```text
打开文件夹 “front”

[添加到当前工作区]
[在当前窗口打开]
[在新窗口打开]
[取消]
```

默认按钮为“添加到当前工作区”。

行为：

- 添加：保留现有文件、标签、终端和 Git 状态。
- 当前窗口打开：沿用现有替换语义，但先检查未保存缓冲。
- 新窗口打开：不影响当前窗口。
- 重复添加同一真实路径时，定位已有根目录，不创建副本。
- 父子目录重叠时给出说明，默认不允许重复添加，避免同一文件出现两个身份。

### 3.3 项目标识

多项目最重要的视觉信号是紧凑的“仓库上下文胶囊”：

```text
[ back / main ⌄ ]
```

它由项目名和当前分支构成，出现在所有 Git 表面的头部。外观沿用系统 material、11pt 字号和现有 Hunk 的紧凑间距，不引入额外大色块。

文件标签默认仍只显示文件名。出现同名文件时补充项目名：

```text
README.md · back
README.md · front
```

提交和比较标签始终显示仓库：

```text
back · a1b2c3
front · develop ↔ origin/develop
```

## 4. Source Control 设计

### 4.1 仓库导航

Source Control 顶部增加常驻的仓库 Section Header 导航。每个仓库标题展示分支和
变更数，当前项用强调色底线标记；点击标题直接原地切换下方的 Changes + History：

```text
REPOSITORIES                                  ↻  ＋
┌─────────┬─────────┬───────────┐
│ ALL  10 │ back  3 │ front  7  │
│ 2 repos │ main    │ develop   │
└─────────┴────━━━━━┴───────────┘

CHANGES                                        3
HISTORY                       [back ⌄]  ↻  ↓  ↑
```

仓库 Section Header 展示：

- 仓库显示名。
- 当前分支。
- 变更数量。
- “全部”范围的仓库数和总变更数。

Header 区域可横向滚动，因此两个项目时全部入口始终一眼可见，项目较多时也不会挤压
Changes 与 History 的纵向空间。History 标题中的仓库胶囊本身也是切换菜单，用户查看
长历史时不必把视线移动到侧边栏底部。

Changes 与 History 之间使用原生可拖拽分隔线，替代当前固定的 230pt History 高度。分隔比例按窗口持久化，双击分隔线恢复默认比例。

### 4.2 Changes

Changes 必须按仓库分组，不提供跨仓库的全局暂存区或全局提交按钮。

规则：

- Commit 输入框属于具体 `RepositorySession`。
- 每个仓库保留自己的提交消息草稿。
- Stage All 仅作用于当前仓库。
- 文件行携带 `RepositoryID + relativePath`。
- 点击变化文件打开的 diff 标签携带仓库 ID。
- `Discard`、`Reset`、`Commit` 等确认文案必须包含仓库名：

```text
丢弃 front 中的 4 项更改？
```

### 4.3 Branches、Worktrees、Stashes、Tags

分支弹层顶部复用仓库上下文胶囊：

```text
[ front / develop ⌄ ]

LOCAL BRANCHES
REMOTE BRANCHES
WORKTREES
STASHES
TAGS
```

切换仓库只替换弹层内容，不改变编辑器标签。每个仓库独立保存：

- 分支过滤关键字。
- 已展开模块。
- 当前选中条目。

跨仓库不提供 merge、cherry-pick 或 compare。未来如果提供跨仓库补丁迁移，应使用明确的 patch/export 工作流，而不是复用 Git 分支操作。

## 5. History 设计

### 5.1 默认：单仓库 History

History 默认跟随 `activeRepositoryID`，完整保留现有泳道图、文件历史、分页、同步操作和右键菜单。

```text
HISTORY                 [back / main ⌄]  ↻ ↓ ↑

│ ●  Add billing endpoint
│ ●  Validate access token
● │  Merge branch feature/auth
│ ●  Initial API skeleton
```

仓库切换器的选项：

- 当前工作区内的每个 Git 仓库。
- 全部仓库。

用户从某个文件打开“查看文件历史”时：

- History 自动切到文件所属仓库。
- 显示文件过滤胶囊。
- 过滤条件记录为 `RepositoryID + relativePath`。

### 5.2 全部仓库：摘要总览而不是混合泳道

“全部仓库”第一版只展示仓库摘要，不直接展示可操作的完整 History。点击仓库或最近提交后进入该仓库的单仓库 History。

```text
HISTORY                                  [全部仓库 ⌄]

● back                   main · 3 changes · ↑1
  Add billing endpoint                     2m

● front               develop · 7 changes · ↓2
  Refine checkout form                      6m

选择一个项目查看完整提交历史、分支、贮藏和标签
```

优化规则：

- 每个仓库显示当前分支、变更数量、ahead/behind、冲突/rebase 状态和最近提交。
- 点击仓库行进入它的完整 graph；点击最近提交直接打开该仓库的提交详情。
- 全部仓库刷新使用有限并发，避免每个仓库同时启动大量 Git 子进程。
- 仓库段按用户在文件树中的顺序排列，不按最近提交时间跳动。
- 可以在标题菜单中切换“仅显示有变更的仓库”。

以后如果确实需要在“全部仓库”中展开历史，可以为每个仓库增加独立 graph 分段和独立分页，但泳道仍不能跨越仓库边界。

不采用“按时间把所有提交混为一张图”的原因：

- 会丢失分支拓扑。
- 相邻两行可能属于完全无关的仓库。
- 对 reset、rebase、compare 等上下文操作容易造成误判。

### 5.3 提交详情

提交详情和 ViewTab 必须绑定 `RepositoryID`：

```swift
case commit(repositoryID: RepositoryID, commit: Repository.Commit)
case compare(repositoryID: RepositoryID, base: String, target: String)
```

提交详情头部显示：

```text
back / main
a1b2c3  Add billing endpoint
```

右键操作使用明确目标：

- 与 back 的 HEAD 比较
- 还原到 back/main
- 摘取到 back/main
- 重置 back/main 到此提交
- 整理 back/main 在此之后的提交

操作开始时捕获 `RepositoryID` 和仓库实例。即使用户在操作期间切到 `front`，结果仍回写到 `back` 的 session。

### 5.4 同步操作

Fetch、Pull、Push 都属于仓库段。

“全部仓库”标题可以提供：

- Refresh All

不提供：

- Fetch All
- Pull All
- Push All

原因是网络操作会触发认证、修改 refs，Pull/Push 还可能修改工作树、触发冲突或发布新分支，不适合隐藏在一个批量动作后。未来若增加，必须先展示逐仓库执行计划和确认结果。

## 6. 编辑器、搜索与终端

### 6.1 文档身份

```swift
struct WorkspaceFileID: Hashable, Codable {
    let folderID: WorkspaceFolderID
    let relativePath: String
}
```

文件标签、缓冲、选择、blame、diff、冲突、文件历史都使用 `WorkspaceFileID`。

不能继续使用相对路径字符串作为全局 ID。

### 6.2 Quick Open

搜索范围默认是整个工作区。结果显示文件夹名：

```text
README.md                     back / docs
README.md                    front / docs
package.json                        front
```

支持前缀限定：

```text
front: checkout
back: token
```

### 6.3 全局搜索

结果先按文件夹分组，再按文件分组。搜索任务携带 folder ID；普通目录使用文件系统搜索，Git 仓库继续复用当前搜索实现。

替换前按文件夹展示受影响文件数量，避免一次跨多个项目写入而用户没有察觉。

### 6.4 终端

每个终端会话在创建时固定 `folderID` 和 `cwd`，之后切换活动仓库不改变已有 shell 的工作目录。

标签显示：

```text
back · zsh 1
front · zsh 1
```

新建终端默认使用当前活动文件所属文件夹；没有活动文件时使用 `activeFolderID`。

## 7. 数据模型

持久化描述：

```swift
struct WorkspaceDescriptor: Identifiable, Codable {
    let id: UUID
    var name: String
    var folders: [WorkspaceFolderDescriptor]
    var activeFolderID: UUID?
    var activeRepositoryID: UUID?
}

struct WorkspaceFolderDescriptor: Identifiable, Codable {
    let id: UUID
    var displayName: String
    var path: String
    var order: Int
}

struct RepositoryDescriptor: Identifiable, Codable {
    let id: UUID
    let folderID: UUID
    let relativeRoot: String
}
```

运行态：

```swift
@MainActor
final class WorkspaceSession: ObservableObject {
    var descriptor: WorkspaceDescriptor
    var folders: [WorkspaceFolderID: FolderSession]
    var repositories: [RepositoryID: RepositorySession]
    var tabs: WorkspaceTabCoordinator
    var documents: DocumentStore
}

@MainActor
final class FolderSession: ObservableObject {
    let id: WorkspaceFolderID
    let rootURL: URL
    var files: [WorkspaceFileID]
    var tree: [WorkspaceFileNode]
    var expandedPaths: Set<String>
}

@MainActor
final class RepositorySession: ObservableObject {
    let id: RepositoryID
    let repository: Repository
    let operations: GitOperationCoordinator

    var snapshot: GitSnapshot
    var history: HistoryState
    var commitDraft: String
    var refreshGeneration: UInt64
}
```

`RepoViewModel` 在迁移期作为界面 façade，逐步把状态转交给 `WorkspaceSession`，而不是一次性重写所有视图。

`GitSnapshot` 一次性包含 changes、branches、stashes、worktrees、tags、currentBranch、sync 和 rebase 状态。并发查询完成后原子替换整个 snapshot，避免界面短暂出现“新 changes + 旧 branch/history”的混合状态。

`GitOperationCoordinator` 保证同一仓库的 stage、commit、checkout、reset、rebase、pull 等写操作串行；不同仓库之间可以并行。History 的过滤器、分页、滚动位置和已开详情保存在各自的 `HistoryState` 中。

## 8. 异步与安全边界

### 8.1 Git 操作

所有 Git 操作签名必须显式接收 `RepositoryID`：

```swift
func stage(repositoryID: RepositoryID, files: [WorkspaceFileID])
func commit(repositoryID: RepositoryID, message: String)
func openCommit(repositoryID: RepositoryID, hash: String)
```

禁止操作函数在异步任务内部重新读取 `activeRepositoryID`。

### 8.2 刷新

- 同一仓库内 refresh 串行合并。
- 跨仓库最多同时刷新两个 session。
- 优先刷新可见、活动或文件系统已变化的仓库。
- 每次刷新携带 generation；旧 generation 返回时丢弃。
- 仓库移除后，未完成任务只允许安全结束，不能回写已删除 session。

### 8.3 未保存缓冲

- 切换活动仓库不关闭标签、不清空 buffers。
- 移除文件夹、替换窗口内容和关闭窗口时统一检查脏缓冲。
- 自动刷新不得覆盖脏缓冲。
- 文档 ID 包含 folder ID，防止同名文件串台。

## 9. 持久化

第一版把工作区描述保存到 Application Support 或 UserDefaults 的 Codable 数据中，不在用户仓库里自动生成配置文件。

最近打开项目区分：

- 单文件夹工作区。
- 多文件夹工作区。

未来可增加显式 `.hunk-workspace` 文件，便于团队共享，但路径可移植、隐私和权限策略需要单独设计。

如果应用启用 App Sandbox，路径持久化改用 security-scoped bookmark。

## 10. 分阶段实施

### Phase 0：先修安全基础

- 为当前 `activateRoot` 增加脏缓冲保护。
- 为异步文件加载、history、diff、blame 增加目标上下文校验。
- 添加现有多仓库扫描和切换测试。

验收：

- 有未保存文件时切换仓库不会静默丢失内容。
- 快速切换仓库不会出现旧任务回写新仓库。

### Phase 1：多根文件工作区

- 引入 `WorkspaceDescriptor`、`WorkspaceFolderID`、`WorkspaceFileID`。
- 拖拽菜单增加“添加到当前工作区”。
- 文件树展示多个顶层根。
- 标签、buffers、Quick Open、搜索结果完成 folder ID 命名空间化。
- 每个终端绑定 folder。
- 工作区可恢复。

验收：

- 可同时添加 `back` 和 `front`。
- 两边的同名文件可以同时打开和保存。
- 切换文件不会丢失另一项目的标签、缓冲和终端。

### Phase 2：多仓库 Source Control

- 引入 `RepositorySession`。
- Changes 按仓库分组。
- 每仓库独立 commit draft、branch、sync、rebase 和冲突状态。
- Git 操作全部显式携带 repository ID。

验收：

- back/front 的 Changes 可同时显示。
- 在 front 文件打开时仍能明确对 back 执行 Git 操作。
- 切换期间的异步操作不会串仓。

### Phase 3：多仓库 History

- History 增加仓库切换器和“全部仓库”摘要。
- 单仓库继续展示完整 graph；全部仓库只展示状态与最近提交。
- commit/compare ViewTab 命名空间化。
- 文件历史绑定仓库。
- Refresh All 使用有限并发。

验收：

- 两个仓库的 graph 不会错误连接。
- 同 hash 或同分支名不会冲突。
- 提交详情、比较、reset、rebase、cherry-pick 始终作用于来源仓库。

### Phase 4：体验完善

- 工作区内重命名、排序和移除根目录。
- 仓库摘要与“仅显示有变更仓库”。
- 搜索范围选择和替换预览。
- 性能与大工作区压力测试。

## 11. 不在本阶段做

- 代码折叠。
- 跨仓库一次性 Commit。
- 把不同仓库的提交混成一张时间线或 graph。
- 隐式跨仓库 Cherry-pick、Merge、Reset。
- 自动生成 `.hunk-workspace` 文件。
- 一次性替换当前全部 `RepoViewModel`。

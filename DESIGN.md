# Hunk — macOS Git 预览编辑器 设计文档

## 目标

一个轻量的 macOS 原生 Git 工作区工具，定位介于 `git status/diff` 命令行和完整 IDE 之间：

- **看**：以语法高亮的方式预览大部分文本文件，以及它们的 diff（统一视图 / 左右分栏视图）。
- **管**：像 VS Code 源代码管理面板一样，左侧区分「已暂存 / 未暂存」，支持树状与扁平两种列表。
- **改**：极简编辑器——只有纯文本编辑、保存、语法高亮；没有补全、没有 LSP、没有插件。
- **操作**：`git add` / 取消暂存 / 行级暂存（hunk 与单行）/ `git stash` / 丢弃更改 / 提交 / 分支切换。
- **同步**：fetch / pull / push，工具栏常驻显示当前分支与上游的 ahead/behind（↑待推送 ↓待拉取），与 VS Code 状态栏一致。
- **冲突**：VS Code 式内联解决——侧边栏单列「合并更改」区，编辑器内高亮冲突块，提供「采用当前更改 / 采用传入更改 / 保留两者」与冲突间跳转，完成后标记为已解决（`git add`）。
- **外观**：Zed 风格的设置弹窗——颜色主题、文件图标主题、编辑器字体与字号均可配置；主题与图标可直接从 open-vsx 下载复用 VS Code 生态资产。

## 非目标

- 不做代码补全、跳转、诊断等 IDE 功能。
- 不做三栏式合并编辑器（冲突采用内联块方案）。
- 不运行 VS Code 扩展代码——只消费 vsix 包里的声明式资产（JSON / SVG）。

## 技术选型

- **SwiftUI**（macOS 14+）作为 UI 框架，编辑器内核用 `NSTextView`（经 `NSViewRepresentable` 桥接），保证大文件编辑性能与原生输入体验。
- **Swift Package Manager** 工程结构，分两个 target：
  - `HunkCore`（纯逻辑库，可单测）：git 进程封装、状态/diff 解析、行级暂存补丁构建、文件树构建。
  - `Hunk`（可执行 App）：SwiftUI 视图与视图模型。
- **git 集成方式**：直接调用系统 `git` CLI（`Process`），不引入 libgit2。理由：零依赖、行为与用户命令行完全一致、porcelain 输出格式稳定。
- **语法高亮**：自研的轻量通用词法着色器（关键字 / 字符串 / 注释 / 数字），按扩展名选择语言定义。覆盖 Swift、C 系、JS/TS、Python、Go、Rust、Ruby、Java/Kotlin、Shell、YAML、JSON、HTML/XML、CSS、SQL、Markdown 等常见语言。不追求 100% 精确，追求零依赖和足够好的观感。
- **open-vsx 资产复用（无 Electron）**：`.vsix` 本质是 zip（JSON 清单 + SVG / 主题 JSON）。
  - 文件图标主题：REST API（`open-vsx.org/api/{ns}/{name}`）下载 vsix → 解压 → 解析
    icon theme JSON（`fileExtensions` / `fileNames` / `folderNames` → SVG）→ `NSImage`
    原生渲染 SVG（CoreSVG，macOS 11+），可近乎完整复用 Material Icon Theme 等。
    内置 SF Symbols 映射作为零网络的默认方案。
  - 颜色主题：解析主题 JSON（容忍 JSONC）的 `colors`（编辑器/diff 背景色）与
    `tokenColors`（TextMate scope → 颜色），把常用 scope 映射到我们词法器的 token
    类型。One Dark Pro / Dracula 等主题观感可基本还原；完整 TextMate 染色需要
    Oniguruma 引擎，留作 v2。
  - 下载是用户在设置里的显式动作，缓存于 `~/Library/Application Support/Hunk/`。

## 架构

```
┌────────────────────────── Hunk (SwiftUI App) ──────────────────────────┐
│  HunkApp ─ ContentView                                                 │
│   ├─ SidebarView（更改 / 文件 / 分支 三个标签）                          │
│   │    ├─ ChangesListView   已暂存 + 未暂存，树状/扁平切换，右键操作      │
│   │    ├─ FilesView         整个工作区文件树（git ls-files）             │
│   │    └─ BranchesView      本地分支 + 贮藏列表                          │
│   ├─ DetailView                                                        │
│   │    ├─ DiffView          统一/分栏 diff，行选择，行级暂存按钮          │
│   │    └─ EditorView        NSTextView 极简编辑器 + 高亮                 │
│   └─ CommitBarView          提交信息 + 提交 / 贮藏按钮                   │
│                          RepoViewModel（@MainActor，所有状态）           │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │ async 调用
┌────────────────────────── HunkCore (库) ───────────────────────────────┐
│  GitClient      Process 封装：git -c core.quotepath=false -C <repo> …  │
│  Repository     高层 API：status / diff / add / restore / stash /      │
│                 commit / branch / apply 行级补丁                        │
│  StatusParser   解析 `git status --porcelain -z`                       │
│  DiffParser     解析 unified diff → FileDiff / DiffHunk / DiffLine     │
│  PatchBuilder   由「选中的行」反向构造补丁，供 git apply --cached 使用    │
│  FileTreeBuilder 路径列表 → 树（目录优先排序），供树状/扁平展示           │
│  SyntaxHighlighter 通用词法着色（在 Hunk target 中做颜色映射）           │
└────────────────────────────────────────────────────────────────────────┘
```

## 关键设计

### 状态模型

`git status --porcelain -z` 的每个条目拆成两个维度：`staged: ChangeKind?` 与
`unstaged: ChangeKind?`。同一文件可以同时出现在两个区域（部分暂存）。未跟踪文件
（`??`）归入未暂存区。

### 行级暂存（核心算法）

对未暂存 diff（工作区 vs 暂存区）选择若干行后构造补丁：

- 上下文行保留；
- 选中的 `-` 行保留，未选中的 `-` 行降级为上下文行（该删除暂不进入暂存区）；
- 选中的 `+` 行保留，未选中的 `+` 行直接丢弃；
- 重新计算 hunk 的行数与起始行（累计前序 hunk 的行数偏移），无选中行的 hunk 整块跳过；
- 结果经 `git apply --cached --whitespace=nowarn -` 写入暂存区。

取消暂存为对称操作：对已暂存 diff（暂存区 vs HEAD），未选中的 `+` 行降级为上下文、
未选中的 `-` 行丢弃，经 `git apply --cached --reverse -` 应用。

未跟踪文件不支持行级暂存（只能整文件 `git add`），这与 git 本身的语义一致。

### Diff 展示

- 统一视图：单列，旧/新双行号 gutter，`+`/`-` 行着色，行内容做逐行语法高亮。
- 分栏视图：hunk 内将连续的删除串与新增串逐行配对成左右两列。
- 二进制文件显示占位提示；图片文件在编辑器区直接预览。

### 编辑器

`NSTextView`：等宽字体、关闭一切自动替换、纯文本。文本变更后防抖 200ms 重新着色
（只改 attributes 不动文本，保持光标）。`⌘S` 保存并刷新 git 状态。

### 远端同步

- ahead/behind 通过 `git rev-list --left-right --count @{upstream}...HEAD` 获取，
  工具栏显示「分支名 ↓n ↑n」；无上游时推送自动 `push -u origin <branch>`。
- 凭据走系统 git 配置（osxkeychain / ssh agent），`GIT_TERMINAL_PROMPT=0` 防卡死，
  认证失败以错误浮层呈现。

### 冲突解决

`ConflictParser` 在文件文本中解析 `<<<<<<<` / `|||||||` / `=======` / `>>>>>>>`
标记 → 冲突块（当前 / 基底 / 传入 + 标签）。编辑器顶部出现冲突操作条：块间跳转、
采用当前 / 采用传入 / 保留两者（纯文本替换，可撤销），全部解决后「标记为已解决」
执行 `git add`。冲突文件在侧边栏独立成「合并更改」区。

### 设置（Zed 风格弹窗，⌘,）

- 外观：颜色主题（跟随系统 / 内置浅色 / 内置深色 / 已下载的 VS Code 主题）、
  文件图标主题（内置 / Material Icon Theme 等）、open-vsx 下载入口。
- 编辑器：等宽字体族选择、字号。
- 全部存 UserDefaults，`AppearanceStore` 统一发布，实时生效。

### 刷新策略

无文件系统监听（第一版）。在以下时机刷新：每次 git 操作后、窗口重新激活时、
手动 ⌘R。

## 提交规划

1. 初始化项目：设计文档与 SPM 骨架
2. Git 核心层：进程封装、状态/diff 解析、行级暂存补丁、冲突解析（含单测与真实仓库集成测试）
3. UI：侧边栏、diff 视图、编辑器、提交/贮藏/分支
4. 远端同步与冲突解决 UI
5. 设置弹窗、语法高亮主题、open-vsx 图标与主题复用

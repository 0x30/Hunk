# Hunk

轻量的 macOS 原生 **Git 预览编辑器**——介于 `git status / diff` 命令行和完整 IDE 之间：
看 diff、管暂存、改文件、解决冲突、提交推送，一个窗口完成。

SwiftUI + 系统 git CLI，零第三方依赖。

## 功能

- **源代码管理侧边栏**（VS Code 风格）
  - 合并更改 / 已暂存 / 更改 三个分区，树状（默认全展开、单子目录链合并）与扁平两种视图
  - 悬停快捷操作与右键菜单：暂存、取消暂存、丢弃、贮藏单文件、Finder 显示
- **Diff 视图**
  - 统一 / 左右分栏两种布局，逐行语法高亮，新增/删除底色
  - **行级暂存**：勾选任意行后一键暂存 / 取消暂存，hunk 级一键操作
- **极简编辑器**：`NSTextView` 内核，等宽字体、防抖语法高亮、⌘S 保存——没有补全，没有 LSP，刻意如此
- **冲突解决**：冲突块背景标色，操作条提供「采用当前 / 采用传入 / 保留两者」、块间跳转、标记为已解决
- **远端同步**：fetch / pull / push，工具栏常驻 `↓落后 ↑领先` 指示，无上游自动 `push -u`
- **分支与贮藏**：切换 / 新建分支，stash push / apply / pop / drop
- **文件浏览**：整个工作区文件树（`git ls-files`），任意文件预览编辑，图片直接预览
- **open-vsx 资产复用（无 Electron）**：vsix 即 zip，只取其中的声明式资产
  - 文件图标主题：默认自动安装 Material Icon Theme，SVG 由 NSImage（CoreSVG）原生渲染
  - 颜色主题：解析 VS Code 主题 JSON（容忍 JSONC），One Dark Pro / Dracula 等观感基本还原
- **设置（⌘,）**：中 / 英双语、等宽字体族与字号、颜色主题、图标主题、扩展下载
- 应用内操作图标全部使用 **SF Symbols**

## open-vsx 主题与图标指南

1. `⌘,` 打开设置，切到「**扩展**」页。
2. 点推荐项的「下载」（Material Icon Theme、One Dark Pro、Dracula、GitHub Theme），
   或在「自定义」输入扩展标识——格式 `namespace.name`，
   在 open-vsx.org 扩展页的 URL 里就能看到（如 `https://open-vsx.org/extension/PKief/material-icon-theme`
   → `PKief.material-icon-theme`）。
3. **文件图标**：「外观 → 文件图标」默认为「自动（优先已安装主题）」，图标主题下载后**立即生效**；
   也可手动指定某个主题或切回内置 SF Symbols。
4. **颜色主题**：下载后到「外观 → 颜色主题」中选择，编辑器与 diff 的语法配色即时切换。
5. 资产缓存于 `~/Library/Application Support/Hunk/extensions/`，
   可在「扩展 → 已安装」中删除。

> 首次启动会自动下载 Material Icon Theme 作为默认文件图标（失败则静默回退 SF Symbols，下次启动重试）。

## 操作速查

| 操作 | 方式 |
|---|---|
| 切换侧边栏标签 | `⌘1` 文件（默认）/ `⌘2` 源代码管理 |
| 内嵌终端 | `⌘J` 弹出/收起（VS Code 式底部面板，工作目录为仓库根，收起不断会话）；终端聚焦时 `⌘N` 新建会话、`⌘W` 结束当前会话；拖拽分隔条调高度（持久记忆） |
| 文件树键盘导航 | `↑↓` 移动，`←` 折叠/回父级，`→` 展开/进子级，`⏎` 打开 |
| 多文件标签 | 顶部标签栏：`⌘W` 关闭，`⌘⇧[` `⌘⇧]` 左右切换，右键关闭其他/已保存/右侧 |
| 暂存/取消暂存整个文件 | 行内悬停 `+`/`−`、右键菜单，或 diff 头部按钮 |
| 暂存单行 | diff 中点击行（或行首勾选框），**选中后头部出现操作条** |
| **连续选多行** | 在左侧行号区按住**拖拽**；或先点一行，再 `⇧+点击`另一行做范围选择 |
| 暂存 / 撤销整个 hunk | hunk 头右侧「暂存此块」/「撤销此块」（撤销带确认） |
| 展开未更改区域 | hunk 之间的「展开 N 行未更改的内容」（GitHub 式） |
| 统一 / 分栏切换 | diff 头部分段控件（默认分栏） |
| 提交 | 底部输入信息后 `⌘⏎` 或点「提交」 |
| 解决冲突 | 点「合并更改」里的文件 → 操作条：`●采用当前`（绿，你的）/ `●采用传入`（蓝，对方的）/ 保留两者 →「标记为已解决」 |
| 这行谁写的 | 编辑器内光标所在行尾灰字显示 blame（作者 · 时间 · 提交消息） |

## 命令行

菜单「Hunk → 安装 hunk 命令行工具…」一键安装到 `/usr/local/bin`（需要一次管理员授权）：

```sh
hunk              # 在 Hunk 中打开当前目录
hunk ~/Projects/x # 打开指定目录
hunk src/main.rs  # 打开文件所在仓库并定位该文件
```

## 构建与运行

需要 macOS 14+ 与 Xcode 命令行工具（系统 `git` 即可，无需 libgit2）。

```sh
swift build            # 构建
swift test             # 运行测试（含真实仓库的行级暂存端到端测试）
swift run Hunk         # 直接运行

Scripts/make-app.sh    # 组装 dist/Hunk.app（release）
open dist/Hunk.app
```

## 工程结构

```
Sources/HunkCore   纯逻辑库：git 进程封装、status/diff 解析、行级暂存补丁、
                   冲突解析、文件树、轻量词法器（可单测）
Sources/Hunk       SwiftUI 应用：视图模型、侧边栏、diff 视图、编辑器、
                   设置、open-vsx 集成
Tests/HunkCoreTests  单元测试 + 临时仓库集成测试
```

设计细节见 [DESIGN.md](DESIGN.md)。

## 已知边界

- 未跟踪文件不支持行级暂存（与 git 语义一致，只能整文件 add）
- 语法高亮为词法级（关键字/字符串/注释/数字），不做完整 TextMate 语法；
  完整 scope 染色需要 Oniguruma 引擎，规划为 v2
- 无文件系统监听，依赖操作后刷新 / 窗口激活刷新 / ⌘R

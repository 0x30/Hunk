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

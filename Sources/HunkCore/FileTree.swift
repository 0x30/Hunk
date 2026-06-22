import Foundation

/// 树状文件列表节点（目录或文件）。
public final class FileNode: Identifiable, Hashable {
    public let path: String   // 相对仓库根的完整路径
    public let name: String
    public let isDirectory: Bool
    public let isIgnored: Bool // 被 .gitignore 忽略：仍展示，但低透明度
    public var children: [FileNode]?

    public init(path: String, name: String, isDirectory: Bool, isIgnored: Bool = false, children: [FileNode]? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isIgnored = isIgnored
        self.children = children
    }

    public var id: String { (isDirectory ? "d:" : "f:") + path }

    public static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 树拍平后的一行（目录或文件），单子目录链已合并为 "a/b/c"；分叉点不再合并。
public struct FlatTreeRow: Identifiable {
    public let node: FileNode
    public let depth: Int
    public let displayName: String
    public var id: String { node.id }

    public init(node: FileNode, depth: Int, displayName: String) {
        self.node = node
        self.depth = depth
        self.displayName = displayName
    }
}

public enum FileTreeBuilder {
    /// 默认隐藏的文件/目录名（对齐 VS Code `files.exclude` 默认值）：
    /// 无论是否被 git 跟踪都完全不在文件树展示。
    public static let defaultHiddenNames: Set<String> = [
        ".DS_Store", "Thumbs.db", ".git", ".svn", ".hg", "CVS",
    ]

    /// 拍平为行列表（默认全展开）。
    /// 只把「单子目录链」合并成一行：某目录恰好只有一个子项且它是目录时，名字
    /// 并入下一层继续合并（/a/b/c/d/f.json → 目录行 "a/b/c/d"）。一旦目录出现
    /// 分叉（多个子项）或含直接文件，就在此停下成行，子目录从这一行往下展开——
    /// 这样 a/b/c/1 与 a/b/e/2 会得到公共枝干 "a/b"，再在其下分出 c、e，而不是
    /// 把前缀重复并进 "a/b/c"、"a/b/e" 两条独立链。
    /// `collapsed` 中的目录路径只输出目录行本身，跳过其子树。
    public static func flattenMergingChains(
        _ nodes: [FileNode],
        depth: Int = 0,
        collapsed: Set<String> = [],
        prefix: String = ""
    ) -> [FlatTreeRow] {
        var result: [FlatTreeRow] = []
        for node in nodes {
            if node.isDirectory {
                let children = node.children ?? []
                let name = prefix.isEmpty ? node.name : prefix + "/" + node.name
                if children.count == 1, children[0].isDirectory {
                    // 单子目录链：不成行，名字并入下一层继续合并
                    result += flattenMergingChains(children, depth: depth, collapsed: collapsed, prefix: name)
                } else {
                    // 分叉点 / 含文件 / 叶子目录：成行，子节点从这一行往下展开
                    result.append(FlatTreeRow(node: node, depth: depth, displayName: name))
                    if !collapsed.contains(node.path) {
                        result += flattenMergingChains(children, depth: depth + 1, collapsed: collapsed)
                    }
                }
            } else {
                result.append(FlatTreeRow(node: node, depth: depth, displayName: node.name))
            }
        }
        return result
    }

    /// 完全展开:每一层目录都各占一行,不做单链合并(a/b/c 拆成三行)。
    /// `collapsed` 中的目录只输出目录行本身,跳过其子树。
    public static func flattenFullTree(
        _ nodes: [FileNode],
        depth: Int = 0,
        collapsed: Set<String> = []
    ) -> [FlatTreeRow] {
        var result: [FlatTreeRow] = []
        for node in nodes {
            if node.isDirectory {
                result.append(FlatTreeRow(node: node, depth: depth, displayName: node.name))
                if !collapsed.contains(node.path) {
                    result += flattenFullTree(node.children ?? [], depth: depth + 1, collapsed: collapsed)
                }
            } else {
                result.append(FlatTreeRow(node: node, depth: depth, displayName: node.name))
            }
        }
        return result
    }

    /// 把路径列表组装成树，目录在前、同级按名称排序。
    /// `ignored` 为被 .gitignore 忽略的条目（`git ls-files --directory` 风格：
    /// 整个被忽略的目录折叠成一条、以 `/` 结尾，避免展开 .build 之类成千上万的文件）。
    /// 这些条目照常进树、但节点 `isIgnored = true`，供视图以低透明度展示。
    /// `hidden` 为「任一层路径命中就整条丢弃、完全不进树」的名字（如 .DS_Store）；
    /// 默认空集——仅文件树视图按用户设置传入，更改列表/历史不受影响。
    public static func build(paths: [String], ignored ignoredEntries: [String] = [], hidden: Set<String> = []) -> [FileNode] {
        final class Builder {
            var files: Set<String> = []
            var dirs: [String: Set<String>] = [:]  // 目录路径 -> 子项名集合
            var ignoredPaths: Set<String> = []     // 被忽略条目的规范化路径（无尾斜杠）
            var hidden: Set<String> = []           // 默认隐藏名(任一层命中即丢弃)

            /// `forceDir` 用于「以 `/` 结尾的忽略目录」——即便它没有列出任何子项，也当目录建节点。
            func insert(_ rawPath: String, ignored: Bool) {
                let forceDir = rawPath.hasSuffix("/")
                let path = forceDir ? String(rawPath.dropLast()) : rawPath
                let components = path.split(separator: "/").map(String.init)
                guard !components.isEmpty else { return }
                // 隐藏项（.DS_Store 等）：任一层命中就整条丢弃，不进树
                if !hidden.isEmpty, components.contains(where: { hidden.contains($0) }) { return }
                if ignored { ignoredPaths.insert(path) }
                var parent = ""
                for (index, name) in components.enumerated() {
                    let full = parent.isEmpty ? name : parent + "/" + name
                    if index == components.count - 1 {
                        if forceDir {
                            dirs[parent, default: []].insert(name)
                            if dirs[full] == nil { dirs[full] = [] }
                        } else {
                            files.insert(full)
                            dirs[parent, default: []].insert(name)
                        }
                    } else {
                        dirs[parent, default: []].insert(name)
                        if dirs[full] == nil { dirs[full] = [] }
                        parent = full
                    }
                }
            }

            // `inheritedIgnored`：父目录被忽略时,子项一律继承忽略(整目录展开后内部也淡色)。
            func nodes(in dir: String, inheritedIgnored: Bool) -> [FileNode] {
                let names = dirs[dir] ?? []
                var result: [FileNode] = []
                for name in names {
                    let full = dir.isEmpty ? name : dir + "/" + name
                    let ignored = inheritedIgnored || ignoredPaths.contains(full)
                    if dirs[full] != nil, !files.contains(full) {
                        result.append(FileNode(path: full, name: name, isDirectory: true, isIgnored: ignored, children: nodes(in: full, inheritedIgnored: ignored)))
                    } else {
                        result.append(FileNode(path: full, name: name, isDirectory: false, isIgnored: ignored))
                    }
                }
                return result.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
        }

        let builder = Builder()
        builder.hidden = hidden
        for path in paths { builder.insert(path, ignored: false) }
        for entry in ignoredEntries { builder.insert(entry, ignored: true) }
        return builder.nodes(in: "", inheritedIgnored: false)
    }
}

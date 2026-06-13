import Foundation

/// 树状文件列表节点（目录或文件）。
public final class FileNode: Identifiable, Hashable {
    public let path: String   // 相对仓库根的完整路径
    public let name: String
    public let isDirectory: Bool
    public var children: [FileNode]?

    public init(path: String, name: String, isDirectory: Bool, children: [FileNode]? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
    }

    public var id: String { (isDirectory ? "d:" : "f:") + path }

    public static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 树拍平后的一行（目录或文件），单子目录链已合并为 "a/b/c"。
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
    /// 拍平为行列表（默认全展开，与 VS Code 一致），并把只有一个子目录的链合并为一行（a/b/c）。
    /// `collapsed` 中的目录路径只输出目录行本身，跳过其子树。
    public static func flattenMergingChains(
        _ nodes: [FileNode],
        depth: Int = 0,
        collapsed: Set<String> = []
    ) -> [FlatTreeRow] {
        var result: [FlatTreeRow] = []
        for node in nodes {
            if node.isDirectory {
                var merged = node
                var name = node.name
                while let children = merged.children,
                      children.count == 1,
                      let only = children.first,
                      only.isDirectory {
                    merged = only
                    name += "/" + only.name
                }
                result.append(FlatTreeRow(node: merged, depth: depth, displayName: name))
                if !collapsed.contains(merged.path) {
                    result += flattenMergingChains(merged.children ?? [], depth: depth + 1, collapsed: collapsed)
                }
            } else {
                result.append(FlatTreeRow(node: node, depth: depth, displayName: node.name))
            }
        }
        return result
    }

    /// 把路径列表组装成树，目录在前、同级按名称排序。
    public static func build(paths: [String]) -> [FileNode] {
        final class Builder {
            var files: Set<String> = []
            var dirs: [String: Set<String>] = [:]  // 目录路径 -> 子项名集合

            func insert(_ path: String) {
                let components = path.split(separator: "/").map(String.init)
                guard !components.isEmpty else { return }
                var parent = ""
                for (index, name) in components.enumerated() {
                    let full = parent.isEmpty ? name : parent + "/" + name
                    if index == components.count - 1 {
                        files.insert(full)
                        dirs[parent, default: []].insert(name)
                    } else {
                        dirs[parent, default: []].insert(name)
                        if dirs[full] == nil { dirs[full] = [] }
                        parent = full
                    }
                }
            }

            func nodes(in dir: String) -> [FileNode] {
                let names = dirs[dir] ?? []
                var result: [FileNode] = []
                for name in names {
                    let full = dir.isEmpty ? name : dir + "/" + name
                    if dirs[full] != nil, !files.contains(full) {
                        result.append(FileNode(path: full, name: name, isDirectory: true, children: nodes(in: full)))
                    } else {
                        result.append(FileNode(path: full, name: name, isDirectory: false))
                    }
                }
                return result.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
        }

        let builder = Builder()
        for path in paths { builder.insert(path) }
        return builder.nodes(in: "")
    }
}

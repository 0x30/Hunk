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

public enum FileTreeBuilder {
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

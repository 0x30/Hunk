import SwiftUI
import HunkCore

struct VirtualizedSidebarRow: ViewModifier {
    let selected: Bool
    let horizontalPadding: CGFloat
    let minHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear)
    }
}

extension View {
    func virtualizedSidebarRow(
        selected: Bool = false,
        horizontalPadding: CGFloat = 8,
        minHeight: CGFloat = 24
    ) -> some View {
        modifier(VirtualizedSidebarRow(
            selected: selected,
            horizontalPadding: horizontalPadding,
            minHeight: minHeight
        ))
    }
}

enum CommitFileListItem: Identifiable {
    case directory(FlatTreeRow)
    case file(Repository.CommitFileChange, depth: Int, showDirectory: Bool)

    var id: String {
        switch self {
        case .directory(let item):
            return "dir:\(item.node.path)"
        case .file(let file, _, _):
            return "file:\(file.path)"
        }
    }

    static func build(
        files: [Repository.CommitFileChange],
        style: FileTreeStyle,
        collapsed: Set<String>
    ) -> [CommitFileListItem] {
        if style == .flat {
            return files.map { .file($0, depth: 0, showDirectory: true) }
        }

        let lookup = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let tree = FileTreeBuilder.build(paths: files.map(\.path))
        let rows = style == .fullTree
            ? FileTreeBuilder.flattenFullTree(tree, collapsed: collapsed)
            : FileTreeBuilder.flattenMergingChains(tree, collapsed: collapsed)

        return rows.compactMap { item in
            if item.node.isDirectory {
                return .directory(item)
            }
            guard let file = lookup[item.node.path] else { return nil }
            return .file(file, depth: item.depth, showDirectory: false)
        }
    }
}

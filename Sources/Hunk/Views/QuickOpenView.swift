import SwiftUI

/// ⌘P 快速打开：模糊匹配工作区文件。
struct QuickOpenView: View {
    @EnvironmentObject var vm: RepoViewModel
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private var matches: [String] {
        Self.filter(vm.workspaceFiles, query: query)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { vm.showQuickOpen = false }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(tr("跳转到文件…", "Go to file…"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { openSelected() }
                        .onKeyPress(.downArrow) {
                            selectedIndex = min(selectedIndex + 1, max(0, matches.count - 1))
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            selectedIndex = max(selectedIndex - 1, 0)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            vm.showQuickOpen = false
                            return .handled
                        }
                }
                .padding(12)

                if !matches.isEmpty {
                    Divider()
                    VStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element) { index, path in
                            resultRow(path: path, highlighted: index == selectedIndex)
                                .onTapGesture {
                                    vm.showQuickOpen = false
                                    vm.revealInFiles(path)
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(width: 540)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .padding(.top, 110)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    private func resultRow(path: String, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            FileIconView(fileName: (path as NSString).lastPathComponent)
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 13))
            Text((path as NSString).deletingLastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(highlighted ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
    }

    private func openSelected() {
        guard matches.indices.contains(selectedIndex) else { return }
        let path = matches[selectedIndex]
        vm.showQuickOpen = false
        vm.revealInFiles(path)
    }

    /// 模糊匹配：文件名前缀 > 文件名包含 > 路径子序列，短路径优先。
    static func filter(_ paths: [String], query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return Array(paths.prefix(10)) }

        var scored: [(score: Int, path: String)] = []
        for path in paths {
            let name = ((path as NSString).lastPathComponent).lowercased()
            let lower = path.lowercased()
            let score: Int
            if name.hasPrefix(trimmed) {
                score = 0
            } else if name.contains(trimmed) {
                score = 1
            } else if isSubsequence(trimmed, of: lower) {
                score = 2
            } else {
                continue
            }
            scored.append((score, path))
        }
        return scored
            .sorted { ($0.score, $0.path.count) < ($1.score, $1.path.count) }
            .prefix(10)
            .map(\.path)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        outer: for char in needle {
            while let candidate = iterator.next() {
                if candidate == char { continue outer }
            }
            return false
        }
        return true
    }
}

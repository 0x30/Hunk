import SwiftUI
import HunkCore

/// ⌘⇧F 全局搜索：git grep 全仓库，按文件分组，↑↓⏎ 键盘导航。
struct GlobalSearchView: View {
    @EnvironmentObject var vm: RepoViewModel
    @State private var query = ""
    @State private var hits: [Repository.GrepHit] = []
    @State private var selectedIndex = 0
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    /// 按文件分组（保持 git grep 的输出顺序）。
    private var groups: [(path: String, hits: [Repository.GrepHit])] {
        var order: [String] = []
        var table: [String: [Repository.GrepHit]] = [:]
        for hit in hits {
            if table[hit.path] == nil { order.append(hit.path) }
            table[hit.path, default: []].append(hit)
        }
        return order.map { ($0, table[$0] ?? []) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { vm.showGlobalSearch = false }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(tr("在仓库中搜索…", "Search in repository…"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { openSelected() }
                        .onKeyPress(.downArrow) {
                            selectedIndex = min(selectedIndex + 1, max(0, hits.count - 1))
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            selectedIndex = max(selectedIndex - 1, 0)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            vm.showGlobalSearch = false
                            return .handled
                        }
                    if searching {
                        ProgressView()
                            .controlSize(.small)
                    } else if !hits.isEmpty {
                        Text(tr("\(hits.count) 个结果", "\(hits.count) results"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)

                if !hits.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(groups, id: \.path) { group in
                                    fileHeader(group.path, count: group.hits.count)
                                    ForEach(group.hits) { hit in
                                        hitRow(hit)
                                            .id(hit.id)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 420)
                        .onChange(of: selectedIndex) { _, index in
                            guard hits.indices.contains(index) else { return }
                            proxy.scrollTo(hits[index].id, anchor: nil)
                        }
                    }
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty, !searching {
                    Divider()
                    Text(tr("没有匹配的结果", "No matches"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, newQuery in
            scheduleSearch(newQuery)
        }
    }

    // MARK: - 行渲染

    private func fileHeader(_ path: String, count: Int) -> some View {
        HStack(spacing: 6) {
            FileIconView(fileName: (path as NSString).lastPathComponent)
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
            Text((path as NSString).deletingLastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .background(Capsule().fill(.quaternary.opacity(0.6)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func hitRow(_ hit: Repository.GrepHit) -> some View {
        let isSelected = hits.indices.contains(selectedIndex) && hits[selectedIndex].id == hit.id
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(hit.line)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
            Text(highlighted(hit.text))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2.5)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            vm.openSearchResult(hit)
        }
    }

    /// 命中词高亮。
    private func highlighted(_ text: String) -> AttributedString {
        let display = String(text.trimmingCharacters(in: .whitespaces).prefix(200))
        var attributed = AttributedString(display)
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return attributed }
        var searchStart = display.startIndex
        while let range = display.range(of: needle, options: .caseInsensitive, range: searchStart..<display.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].foregroundColor = .accentColor
                attributed[lower..<upper].font = .system(size: 12, weight: .bold, design: .monospaced)
            }
            searchStart = range.upperBound
        }
        return attributed
    }

    // MARK: - 搜索

    private func scheduleSearch(_ newQuery: String) {
        searchTask?.cancel()
        selectedIndex = 0
        let trimmed = newQuery.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            hits = []
            searching = false
            return
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let repo = vm.repo else { return }
            let result = (try? await repo.grep(trimmed)) ?? []
            guard !Task.isCancelled else { return }
            hits = result
            searching = false
        }
    }

    private func openSelected() {
        guard hits.indices.contains(selectedIndex) else { return }
        vm.openSearchResult(hits[selectedIndex])
    }
}

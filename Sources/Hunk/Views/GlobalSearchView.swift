import SwiftUI
import HunkCore

/// 全局搜索面板（⌘⇧F / ⌘⇧R）：占据右侧详情区，类似 Zed —— 顶部 header（查询 + 选项），
/// 其下按文件分组、文件头吸顶、匹配行一直罗列下去。不再是弹出框。
/// 查询与结果存在视图模型里，开/关面板不丢失（点结果打开文件后 ⌘⇧F 可原样回到列表）。
struct SearchPanelView: View {
    @EnvironmentObject var vm: RepoViewModel
    @State private var replacement = ""
    @State private var selectedIndex = 0
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var confirmReplace = false
    @FocusState private var focusField: Field?

    private enum Field { case search, replace }

    /// 替换模式强制精确匹配（区分大小写、字面量），保证「搜得到的就是会被替换的」。
    private var effectiveExact: Bool { vm.globalSearchReplace || vm.globalSearchExact }
    private var hits: [Repository.GrepHit] { vm.globalSearchHits }
    private var needle: String { vm.globalSearchQuery.trimmingCharacters(in: .whitespaces) }
    private var fileCount: Int { Set(hits.map(\.path)).count }
    private var canReplace: Bool {
        effectiveExact && !needle.isEmpty && !hits.isEmpty && needle != replacement
    }

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
        VStack(spacing: 0) {
            header
            Divider()
            if !hits.isEmpty || searching {
                countBar
                Divider()
            }
            results
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            // 首次出现时视图刚成为第一响应者,同帧设焦点会被吞,延到下一帧(与 nonce 路径一致)
            DispatchQueue.main.async { focusField = vm.globalSearchReplace ? .replace : .search }
            // 复用缓存结果时不重搜；首次或查询变更才搜
            if hits.isEmpty { scheduleSearch(vm.globalSearchQuery) }
        }
        // 标签已存在时再按 ⌘⇧F 不重走 onAppear，靠 nonce 每次都把焦点+全选还给输入框。
        // 下一帧再设：切到搜索标签后视图才成为第一响应者，同帧设焦点会被吞。
        .onChange(of: vm.searchFocusNonce) { _, _ in
            DispatchQueue.main.async { focusField = vm.globalSearchReplace ? .replace : .search }
        }
        .onChange(of: vm.globalSearchQuery) { _, q in scheduleSearch(q) }
        .onChange(of: vm.globalSearchExact) { _, _ in scheduleSearch(vm.globalSearchQuery) }
        .confirmationDialog(
            tr("在 \(fileCount) 个文件中替换全部「\(needle)」？",
               "Replace all “\(needle)” in \(fileCount) file(s)?"),
            isPresented: $confirmReplace,
            titleVisibility: .visible
        ) {
            Button(tr("全部替换", "Replace All"), role: .destructive) {
                let q = needle, r = replacement
                Task { await vm.replaceAllInRepo(query: q, replacement: r) }
            }
            Button(tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("将直接改写文件（含未跟踪文件）。已跟踪文件可用 git 撤销，未跟踪文件无法撤销。",
                    "Files will be modified on disk (including untracked). Tracked files can be reverted via git; untracked files cannot."))
        }
    }

    // MARK: - 顶部 header

    private var header: some View {
        VStack(spacing: 5) {
            // 一行搞定：Xcode 式「查找 / 替换」下拉 + 搜索框 + 关闭，尽量紧凑
            HStack(spacing: 6) {
                Menu {
                    Button(tr("查找", "Find")) { vm.globalSearchReplace = false }
                    Button(tr("替换", "Replace")) { vm.globalSearchReplace = true }
                } label: {
                    HStack(spacing: 3) {
                        Text(vm.globalSearchReplace ? tr("替换", "Replace") : tr("查找", "Find"))
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                searchField

                Button { vm.closeSearchTab() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(tr("关闭 (⎋)", "Close (⎋)"))
            }

            if vm.globalSearchReplace { replaceField }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// 紧凑的圆角搜索框（含 Aa 精确匹配 + 清除）。
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(tr("在仓库中搜索…", "Search in repository…"), text: $vm.globalSearchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focusField, equals: .search)
                .onSubmit { onSearchSubmit() }
                .onKeyPress(.downArrow) { moveSelection(1) }
                .onKeyPress(.upArrow) { moveSelection(-1) }
                .onKeyPress(.escape) { vm.closeSearchTab(); return .handled }
            Button { vm.globalSearchExact.toggle() } label: {
                Text("Aa")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(effectiveExact ? Color.accentColor.opacity(0.25) : .clear))
            }
            .buttonStyle(.plain)
            .foregroundStyle(effectiveExact ? Color.accentColor : .secondary)
            .disabled(vm.globalSearchReplace)
            .help(tr("精确匹配（区分大小写）", "Match exactly (case-sensitive)"))
            if !vm.globalSearchQuery.isEmpty {
                Button { vm.globalSearchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }

    private var replaceField: some View {
        HStack(spacing: 5) {
            Image(systemName: "pencil")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(tr("替换为…", "Replace with…"), text: $replacement)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focusField, equals: .replace)
                .onSubmit { if canReplace { confirmReplace = true } }
                .onKeyPress(.escape) { vm.closeSearchTab(); return .handled }
            Button(tr("全部替换", "Replace All")) { confirmReplace = true }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(!canReplace)
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }

    /// 结果统计条（Xcode 式居中「N results in M files」）。
    private var countBar: some View {
        HStack(spacing: 6) {
            if searching {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(tr("搜索中…", "Searching…"))
            } else {
                Text(tr("\(hits.count) 处匹配 · \(fileCount) 个文件",
                        "\(hits.count) results in \(fileCount) files"))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
    }

    // MARK: - 结果列表（文件头吸顶，一直罗列）

    @ViewBuilder
    private var results: some View {
        if !hits.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.path) { group in
                            Section(header: fileHeader(group.path, count: group.hits.count)) {
                                ForEach(group.hits) { hit in
                                    hitRow(hit).id(hit.id)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: selectedIndex) { _, index in
                    guard hits.indices.contains(index) else { return }
                    proxy.scrollTo(hits[index].id, anchor: .center)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.quaternary)
                Text(needle.isEmpty
                     ? tr("输入关键字搜索整个仓库", "Type to search the whole repository")
                     : (searching ? tr("搜索中…", "Searching…") : tr("没有匹配的结果", "No matches")))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

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
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 0.5)
        }
    }

    private func hitRow(_ hit: Repository.GrepHit) -> some View {
        let isSelected = hits.indices.contains(selectedIndex) && hits[selectedIndex].id == hit.id
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(hit.line)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
            Text(highlighted(hit.text))
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if let i = hits.firstIndex(where: { $0.id == hit.id }) { selectedIndex = i }
            vm.openSearchResult(hit)
        }
    }

    /// 命中词高亮。
    private func highlighted(_ text: String) -> AttributedString {
        let display = String(text.trimmingCharacters(in: .whitespaces).prefix(240))
        var attributed = AttributedString(display)
        guard !needle.isEmpty else { return attributed }
        var searchStart = display.startIndex
        while let range = display.range(of: needle, options: .caseInsensitive, range: searchStart..<display.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].foregroundColor = .accentColor
                attributed[lower..<upper].font = .system(size: 12.5, weight: .bold, design: .monospaced)
            }
            searchStart = range.upperBound
        }
        return attributed
    }

    // MARK: - 行为

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard !hits.isEmpty else { return .ignored }
        selectedIndex = max(0, min(hits.count - 1, selectedIndex + delta))
        return .handled
    }

    private func onSearchSubmit() {
        if vm.globalSearchReplace {
            focusField = .replace
        } else if hits.indices.contains(selectedIndex) {
            vm.openSearchResult(hits[selectedIndex])
        }
    }

    // MARK: - 搜索

    private func scheduleSearch(_ newQuery: String) {
        searchTask?.cancel()
        selectedIndex = 0
        let trimmed = newQuery.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            vm.globalSearchHits = []
            searching = false
            return
        }
        searching = true
        let exact = effectiveExact
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let repo = vm.repo else {
                await MainActor.run { searching = false }
                return
            }
            let result = (try? await repo.grep(trimmed, exact: exact)) ?? []
            guard !Task.isCancelled else { return }
            vm.globalSearchHits = result
            searching = false
        }
    }
}

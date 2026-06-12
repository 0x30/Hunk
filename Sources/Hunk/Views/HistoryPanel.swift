import SwiftUI
import HunkCore

/// 源代码管理底部的提交历史：全分支 graph，或单文件历史（过滤模式）。
struct HistoryPanel: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(tr("历史", "History"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let path = vm.historyFilterPath {
                    HStack(spacing: 3) {
                        Image(systemName: "doc")
                            .font(.system(size: 8))
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Button {
                            vm.setHistoryFilter(nil)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help(tr("清除文件过滤，显示全部历史", "Clear filter, show full history"))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
                }

                Spacer()

                if let upstream = vm.sync.upstream {
                    Button {
                        vm.openHistoryDetail(.compare(base: upstream, target: "HEAD"))
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(tr("比较 \(upstream) ↔ 本地分支", "Compare \(upstream) ↔ local branch"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider()

            List {
                ForEach(vm.history) { entry in
                    if let commit = entry.commit {
                        HistoryRow(entry: entry, commit: commit)
                    } else {
                        // 纯图形延续行（"|/" 之类）
                        Text(entry.graph)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 4))
                            .frame(height: 9)
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 14)
        }
        .frame(height: 230)
    }
}

private struct HistoryRow: View {
    @EnvironmentObject var vm: RepoViewModel
    let entry: Repository.LogEntry
    let commit: Repository.Commit

    private var isActive: Bool {
        if case .commit(let current) = vm.historyDetail { return current.hash == commit.hash }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if !entry.graph.isEmpty {
                Text(entry.graph)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    ForEach(commit.refs.prefix(3), id: \.self) { ref in
                        Text(shortRef(ref))
                            .font(.system(size: 8.5, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(refColor(ref).opacity(0.18)))
                            .foregroundStyle(refColor(ref))
                            .lineLimit(1)
                    }
                    Text(commit.subject)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                }
                Text("\(commit.shortHash) · \(commit.author) · \(relative(commit.date))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 4))
        .listRowBackground(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            vm.openHistoryDetail(.commit(commit))
        }
        .contextMenu {
            Button(tr("查看此提交的更改", "View Changes in This Commit")) {
                vm.openHistoryDetail(.commit(commit))
            }
            Divider()
            Button(tr("与 HEAD 比较", "Compare with HEAD")) {
                vm.openHistoryDetail(.compare(base: commit.hash, target: "HEAD"))
            }
            if let upstream = vm.sync.upstream {
                Button(tr("与 \(upstream) 比较", "Compare with \(upstream)")) {
                    vm.openHistoryDetail(.compare(base: commit.hash, target: upstream))
                }
            }
            Divider()
            Button(tr("复制提交哈希", "Copy Commit Hash")) {
                vm.copyPath(commit.hash)
            }
        }
        .help("\(commit.subject)\n\(commit.author) · \(commit.hash)")
    }

    private func shortRef(_ ref: String) -> String {
        ref.replacingOccurrences(of: "HEAD -> ", with: "→ ")
            .replacingOccurrences(of: "tag: ", with: "🏷 ")
    }

    private func refColor(_ ref: String) -> Color {
        if ref.contains("HEAD") { return .accentColor }
        if ref.hasPrefix("tag:") { return .orange }
        if ref.contains("/") { return .purple }  // 远程分支
        return .green                            // 本地分支
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 历史详情（提交内容 / 引用比较）

struct HistoryDetailView: View {
    @EnvironmentObject var vm: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                fileList
                    .frame(width: 250)
                Divider()
                if let diff = vm.historyDiff {
                    ReadOnlyDiffView(diff: diff)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.quaternary)
                        Text(tr("选择左侧文件查看差异", "Select a file to view its diff"))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                vm.closeHistoryDetail()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(tr("关闭", "Close"))

            switch vm.historyDetail {
            case .commit(let commit):
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.subject)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("\(commit.shortHash) · \(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .compare(let base, let target):
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                Text("\(shortRef(base)) ↔ \(shortRef(target))")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            case nil:
                EmptyView()
            }

            Spacer()

            Text(tr("\(vm.historyFiles.count) 个文件", "\(vm.historyFiles.count) files"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func shortRef(_ ref: String) -> String {
        ref.count > 12 && ref.allSatisfy(\.isHexDigit) ? String(ref.prefix(8)) : ref
    }

    private var fileList: some View {
        List {
            ForEach(vm.historyFiles) { file in
                HStack(spacing: 6) {
                    FileIconView(fileName: (file.path as NSString).lastPathComponent)
                    VStack(alignment: .leading, spacing: 0) {
                        Text((file.path as NSString).lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Text((file.path as NSString).deletingLastPathComponent)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(file.kind.badge)
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(file.kind.color)
                }
                .padding(.vertical, 1)
                .contentShape(Rectangle())
                .listRowBackground(
                    vm.historyDiffPath == file.path ? Color.accentColor.opacity(0.12) : Color.clear
                )
                .onTapGesture {
                    vm.selectHistoryFile(file)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 26)
    }
}

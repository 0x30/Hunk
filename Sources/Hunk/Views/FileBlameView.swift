import SwiftUI
import HunkCore

/// 整文件 blame 视图：按提交分块，左侧归属信息，右侧代码。
/// 点击块的归属信息可查看那次提交的全部更改。
struct FileBlameView: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore
    let path: String

    private struct Block: Identifiable {
        let id: Int
        let hash: String
        let author: String
        let summary: String
        let date: Date?
        let isUncommitted: Bool
        let startLine: Int
        let lines: [Repository.BlameLine]
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var current: [Repository.BlameLine] = []
        for line in vm.fileBlame {
            if let last = current.last, last.hash != line.hash {
                result.append(makeBlock(id: result.count, lines: current))
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty {
            result.append(makeBlock(id: result.count, lines: current))
        }
        return result
    }

    private func makeBlock(id: Int, lines: [Repository.BlameLine]) -> Block {
        let first = lines[0]
        return Block(
            id: id,
            hash: first.hash,
            author: first.author,
            summary: first.summary,
            date: first.date,
            isUncommitted: first.isUncommitted,
            startLine: first.line,
            lines: lines
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.fileBlame.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(tr("正在分析归属…", "Analyzing blame…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical]) {
                    LazyVStack(spacing: 0) {
                        ForEach(blocks) { block in
                            blockRow(block)
                            Divider().opacity(0.4)
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func blockRow(_ block: Block) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // 归属列
            VStack(alignment: .leading, spacing: 1) {
                Text(block.isUncommitted ? tr("未提交", "Uncommitted") : block.author)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if !block.isUncommitted {
                        Text(String(block.hash.prefix(7)))
                            .font(.system(size: 9.5, design: .monospaced))
                    }
                    if let date = block.date {
                        Text(relative(date))
                            .font(.system(size: 9.5))
                    }
                }
                .foregroundStyle(.tertiary)
                if !block.summary.isEmpty {
                    Text(block.summary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(width: 190, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)  // 撑满整个块的高度，色块覆盖全部行
            .background(blockTint(block).opacity(0.10))
            .overlay(alignment: .leading) {
                Rectangle().fill(blockTint(block).opacity(0.7)).frame(width: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !block.isUncommitted else { return }
                vm.openHistoryDetail(.commit(Repository.Commit(
                    hash: block.hash,
                    shortHash: String(block.hash.prefix(7)),
                    author: block.author,
                    subject: block.summary,
                    date: block.date ?? Date(),
                    refs: []
                )))
            }
            .help(block.isUncommitted
                  ? tr("尚未提交的更改", "Uncommitted changes")
                  : tr("点击查看这次提交的全部更改", "Click to view all changes in this commit"))

            // 代码列
            VStack(alignment: .leading, spacing: 0) {
                ForEach(block.lines, id: \.line) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("\(line.line)")
                            .frame(width: 40, alignment: .trailing)
                            .foregroundStyle(.tertiary)
                        Text(line.text.isEmpty ? " " : line.text)
                            .padding(.leading, 10)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: settings.editorFontSize - 1, design: .monospaced))
                }
            }
            .padding(.vertical, 3)
        }
    }

    /// 按哈希派生一个稳定的色相，让不同提交的块肉眼可分。
    private func blockTint(_ block: Block) -> Color {
        if block.isUncommitted { return .orange }
        let hue = Double(abs(block.hash.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

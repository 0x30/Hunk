import SwiftUI
import HunkCore

/// 整文件 blame 视图：按提交分块，左侧归属信息，右侧代码。
/// 点击块的归属信息可查看那次提交的全部更改。
///
/// 关键：整文件铺成「单层 LazyVStack 逐行」而不是「按块 + 块内非懒加载 VStack」。
/// 否则一段同提交的大块（大文件常整份同一次提交）会把成千上万个 Text 一次性实例化，
/// TextKit 排版 + CALayer 背板让图层内存（RSS）瞬间涨到数 GB 致 OOM——
/// 这是 diff 行那个问题（commit 8e0d96e）的孪生。逐行后只排版可视区。
struct FileBlameView: View {
    @EnvironmentObject var vm: RepoViewModel
    @EnvironmentObject var settings: SettingsStore
    let path: String

    /// 一行 blame：携带它在所属提交段内的序号，段首一两行用来显示归属文字。
    private struct Row: Identifiable {
        let id: Int
        let line: Repository.BlameLine
        /// 行在所属提交段内的序号（0 = 段首），用来决定显示哪一段归属文字。
        let runOffset: Int
        /// 是否是该提交段的最后一行（其后画分隔线）。
        let isRunEnd: Bool
        let hash: String
        let author: String
        let summary: String
        let date: Date?
        let isUncommitted: Bool
    }

    private var rows: [Row] {
        let blame = vm.fileBlame
        var result: [Row] = []
        result.reserveCapacity(blame.count)
        var offset = 0
        for (i, line) in blame.enumerated() {
            let prevHash = i > 0 ? blame[i - 1].hash : nil
            let nextHash = i + 1 < blame.count ? blame[i + 1].hash : nil
            offset = (line.hash == prevHash) ? offset + 1 : 0
            result.append(Row(
                id: i,
                line: line,
                runOffset: offset,
                isRunEnd: line.hash != nextHash,
                hash: line.hash,
                author: line.author,
                summary: line.summary,
                date: line.date,
                isUncommitted: line.isUncommitted
            ))
        }
        return result
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
                        ForEach(rows) { row in
                            rowView(row)
                            if row.isRunEnd {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 0) {
            // 归属色带：色块铺满整行高度连成一条带，文字只在段首一两行出现。
            attribution(row)
                .padding(.horizontal, 10)
                .padding(.vertical, row.runOffset == 0 ? 3 : 0)
                .frame(width: 190, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(blockTint(row).opacity(0.10))
                .overlay(alignment: .leading) {
                    Rectangle().fill(blockTint(row).opacity(0.7)).frame(width: 2)
                }
                .contentShape(Rectangle())
                .onTapGesture { openCommit(row) }
                .help(row.isUncommitted
                      ? tr("尚未提交的更改", "Uncommitted changes")
                      : tr("点击查看这次提交的全部更改", "Click to view all changes in this commit"))

            // 代码列
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(row.line.line)")
                    .frame(width: 40, alignment: .trailing)
                    .foregroundStyle(.tertiary)
                Text(verbatim: row.line.text.isEmpty ? " " : row.line.text)
                    .padding(.leading, 10)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: settings.editorFontSize - 1, design: .monospaced))
            .padding(.vertical, 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 段首行显示作者 + 短哈希 + 日期；段内第二行显示提交说明；其余行只留色带。
    @ViewBuilder
    private func attribution(_ row: Row) -> some View {
        if row.runOffset == 0 {
            HStack(spacing: 4) {
                Text(row.isUncommitted ? tr("未提交", "Uncommitted") : row.author)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if !row.isUncommitted {
                    Text(String(row.hash.prefix(7)))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let date = row.date {
                    Text(relative(date))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        } else if row.runOffset == 1, !row.summary.isEmpty {
            Text(row.summary)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Color.clear
        }
    }

    private func openCommit(_ row: Row) {
        guard !row.isUncommitted else { return }
        vm.openHistoryDetail(.commit(Repository.Commit(
            hash: row.hash,
            shortHash: String(row.hash.prefix(7)),
            author: row.author,
            subject: row.summary,
            date: row.date ?? Date(),
            refs: []
        )))
    }

    /// 按哈希派生一个稳定的色相，让不同提交的块肉眼可分。
    private func blockTint(_ row: Row) -> Color {
        if row.isUncommitted { return .orange }
        let hue = Double(abs(row.hash.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    private func relative(_ date: Date) -> String {
        relativeTime(date)
    }
}

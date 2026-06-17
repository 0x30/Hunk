import SwiftUI
import AppKit
import CryptoKit
import HunkCore

/// 提交悬浮卡：blame 行内注解 / 全文 blame 视图悬浮或点击时弹出，
/// 展示这一次提交的完整信息（含多行消息，行内注解一行装不下的就靠它）。
/// 自身不画卡片底色——交给宿主 NSPopover / SwiftUI popover 的材质 chrome。
struct CommitCard: View {
    let hash: String
    /// 取提交详情（VM 缓存包一层即可）。
    var fetch: (String) async -> Repository.CommitDetail?
    /// 点「查看此提交」：在历史详情打开它。
    var onViewCommit: (Repository.CommitDetail) -> Void
    /// 悬浮桥接：鼠标进/出卡片时回调，预览态据此决定是否自动收起。
    var onHoverChange: (Bool) -> Void = { _ in }
    /// 关闭请求（点「查看此提交」后收起浮窗）。
    var onClose: () -> Void = {}
    /// 是否显示「查看此提交」按钮（内嵌到提交详情头部时关掉——已经在看了）。
    var showViewButton: Bool = true
    /// 固定宽度（popover 用 360）；nil = 撑满可用宽度（内嵌横幅用）。
    var fixedWidth: CGFloat? = 360

    @State private var detail: Repository.CommitDetail?
    @State private var loadFailed = false
    @State private var copied = false

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if loadFailed {
                Text(tr("无法加载该提交", "Couldn’t load this commit"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("加载中…", "Loading…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
        .frame(maxWidth: fixedWidth ?? .infinity, alignment: .leading)
        .onHover { onHoverChange($0) }
        .task(id: hash) {
            detail = await fetch(hash)
            loadFailed = detail == nil
        }
    }

    @ViewBuilder
    private func content(_ d: Repository.CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：头像 + 作者/邮箱 + 短哈希（可复制）
            HStack(spacing: 10) {
                avatar(author: d.author, email: d.email)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.author)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    if !d.email.isEmpty {
                        Text(d.email)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(d.hash, forType: .string)
                    copied = true
                } label: {
                    HStack(spacing: 4) {
                        Text(d.shortHash)
                            .font(.system(size: 11.5, design: .monospaced))
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(copied ? Color.green : Color.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("复制完整哈希", "Copy full hash"))
            }

            // 时间：相对 + 绝对
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                Text("\(relativeTime(d.date)) · \(Self.absoluteFormatter.string(from: d.date))")
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(.tertiary)
            .padding(.top, 8)

            Divider().padding(.vertical, 10)

            // 完整提交消息：标题加粗，正文多行（长则滚动）
            Text(d.subject)
                .font(.system(size: 13, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !d.body.isEmpty {
                ScrollView {
                    Text(d.body)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(.top, 6)
            }

            // 底部：文件数 + 查看此提交
            HStack(spacing: 8) {
                Label(
                    tr("改动 \(d.filesChanged) 个文件", "\(d.filesChanged) file(s)"),
                    systemImage: "doc.text"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                Spacer()
                if showViewButton {
                    Button {
                        onViewCommit(d)
                        onClose()
                    } label: {
                        Label(tr("查看此提交", "View commit"), systemImage: "arrow.up.forward.square")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.top, 11)
        }
        .padding(14)
    }

    /// 头像：优先 Gravatar（按邮箱），没有则回退到首字母色块。
    @ViewBuilder
    private func avatar(author: String, email: String) -> some View {
        if let url = Self.gravatarURL(email: email) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    // 加载中 / 无 Gravatar（d=404 → 失败）都回退首字母
                    initialAvatar(author)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
        } else {
            initialAvatar(author)
        }
    }

    /// 首字母色块：按 hash 派生稳定色相（与 blame 视图块色一致的思路）。
    private func initialAvatar(_ author: String) -> some View {
        let initial = author.first.map { String($0).uppercased() } ?? "?"
        let hue = Double(abs(hash.hashValue % 360)) / 360.0
        let tint = Color(hue: hue, saturation: 0.5, brightness: 0.7)
        return Text(initial)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(tint))
    }

    /// Gravatar 头像地址：邮箱小写去空白后 MD5；d=404 让「没有头像」直接失败以触发回退。
    private static func gravatarURL(email: String) -> URL? {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let hex = Insecure.MD5.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hex)?d=404&s=80")
    }
}

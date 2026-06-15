import SwiftUI
import HunkCore

/// 只读 hex 查看器：`offset | 十六进制 | ASCII`。打开二进制文件时替代纯文本编辑器。
/// 大文件限读前 maxBytes，避免吃内存；按 16 字节一行用 LazyVStack 懒渲染。
struct HexView: View {
    @EnvironmentObject var settings: SettingsStore
    let url: URL

    private static let maxBytes = 1_048_576  // 1 MB

    @State private var data = Data()
    @State private var truncated = false
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if data.isEmpty {
                Text(tr("空文件", "Empty file"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(stride(from: 0, to: data.count, by: 16)), id: \.self) { start in
                            row(at: start)
                        }
                        if truncated {
                            Text(tr("…（仅显示前 \(Self.maxBytes / 1024) KB）",
                                    "…(showing first \(Self.maxBytes / 1024) KB)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: url) { await load() }
    }

    private func load() async {
        loaded = false
        let max = Self.maxBytes
        let target = url
        let result: (Data, Bool) = await Task.detached(priority: .userInitiated) {
            guard let handle = try? FileHandle(forReadingFrom: target) else { return (Data(), false) }
            defer { try? handle.close() }
            let chunk = (try? handle.read(upToCount: max + 1)) ?? Data()
            if chunk.count > max { return (Data(chunk.prefix(max)), true) }
            return (Data(chunk), false)
        }.value
        data = result.0
        truncated = result.1
        loaded = true
    }

    private func row(at start: Int) -> some View {
        let end = min(start + 16, data.count)
        let bytes = [UInt8](data.subdata(in: start..<end))
        let cols = (0..<16).map { i in i < bytes.count ? String(format: "%02X", bytes[i]) : "  " }
        let hexStr = cols[0..<8].joined(separator: " ") + "  " + cols[8..<16].joined(separator: " ")
        let ascii = String(bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "·" })
        return HStack(spacing: 16) {
            Text(String(format: "%08X", start)).foregroundStyle(.tertiary)
            Text(hexStr)
            Text(ascii).foregroundStyle(.secondary)
        }
        .font(.system(size: settings.editorFontSize - 1, design: .monospaced))
        .padding(.horizontal, 12)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

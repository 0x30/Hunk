import Foundation

/// 文件系统中转的命令行打开请求。
///
/// 请求文件必须先写入隐藏临时文件，再原子改名为 `cli-open.*`；这样目录
/// 监视器不会在路径尚未写完时消费它。`cli-open` 作为旧版启动脚本的兼容文件保留。
public enum CLIOpenRequestStore {
    public static let legacyFileName = "cli-open"
    public static let queuedFilePrefix = "cli-open."

    /// 是否存在待处理请求。空文件也算存在，避免旧版脚本写入期间恢复上次项目。
    public static func hasPendingRequest(in directory: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path) else { return false }
        return names.contains { $0 == legacyFileName || $0.hasPrefix(queuedFilePrefix) }
    }

    /// 读取并删除完整请求。空文件或非法 UTF-8 文件会保留，等待下一次写入事件。
    public static func consume(in directory: URL) -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        let candidates = urls.filter { url in
            let name = url.lastPathComponent
            return name == legacyFileName || name.hasPrefix(queuedFilePrefix)
        }.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            return (l ?? .distantPast) < (r ?? .distantPast)
        }

        var paths: [String] = []
        for url in candidates {
            guard let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty else { continue }
            try? FileManager.default.removeItem(at: url)
            paths.append(raw)
        }
        return paths
    }
}

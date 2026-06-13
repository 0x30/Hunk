import Foundation

/// 诊断日志：把关键事件 + 当时的内存占用实时写入磁盘。
///
/// 目的：内存暴涨/被 OOM 杀掉后能复盘——看日志末尾就知道崩溃前在做什么、内存怎么涨的。
/// 每条立即用 `write` 落到内核（不缓冲在进程里），即便被 SIGKILL 也不丢已写内容。
/// 每条都带当前物理内存，所以哪个操作让内存跳一目了然。
///
/// 日志位置：~/Library/Logs/Hunk/session.log（上一会话备份为 session.prev.log）。
enum Diagnostics {
    private static let lock = NSLock()
    private static var handle: FileHandle?

    /// 日志目录（~/Library/Logs/Hunk）
    static var directory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Hunk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var logURL: URL { directory.appendingPathComponent("session.log") }

    static func start() {
        let url = logURL
        let prev = directory.appendingPathComponent("session.prev.log")
        // 轮转：本次启动把上一会话日志备份，开新文件，避免无限增长
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: url, to: prev)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        log("=== 会话开始 (build \(bundleVersion)) ===")
    }

    /// 记录一行：`时间 [内存MB] 消息`。线程安全、立即落盘。
    static func log(_ message: @autoclosure () -> String) {
        let mb = MemoryGuard.footprintBytes() / 1_048_576
        let stamp = timestamp()
        let line = "\(stamp) [\(mb)MB] \(message())\n"
        lock.lock()
        defer { lock.unlock() }
        if let data = line.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
    }

    /// 轻量时间戳（避免 DateFormatter 开销）：HH:mm:ss.mmm
    private static func timestamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var t = tv.tv_sec
        var tmResult = tm()
        localtime_r(&t, &tmResult)
        let ms = tv.tv_usec / 1000
        return String(format: "%02d:%02d:%02d.%03d",
                      tmResult.tm_hour, tmResult.tm_min, tmResult.tm_sec, ms)
    }
}

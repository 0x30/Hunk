import Foundation

/// 二进制文件检测：仿 git——读文件头若干字节，含 NUL(0x00) 即判定为二进制。
public enum BinaryDetector {
    /// 读文件头 sampleSize 字节，含 NUL 字节则视为二进制。读不到按非二进制处理。
    public static func isBinary(url: URL, sampleSize: Int = 8000) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: sampleSize)) ?? Data()
        return data.contains(0)
    }
}

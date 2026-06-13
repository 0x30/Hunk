import Foundation
import Darwin

/// 内存看门狗：定期检查自身物理内存占用。
///
/// 背景：曾出现内存暴涨到数百 GB、触发系统级 OOM 把用户其它应用（微信等）一起杀掉。
/// 在没拿到崩溃堆栈、根因未定位前，这是兜底——宁可 Hunk 自己退出，也不拖垮整个系统；
/// 同时把异常时的内存快照写入日志，便于下次复现定位。
enum MemoryGuard {
    /// 软阈值：清缓存、记录（正常 Hunk 约 250MB，看大文件 diff 也就几百 MB）
    private static let softLimitMB: UInt64 = 1500
    /// 硬阈值：已明显失控，记录详情后主动退出，避免连累系统
    private static let hardLimitMB: UInt64 = 6000

    private static var timer: Timer?
    private static var warned = false
    /// 上次采样的内存，用于检测快速增长
    private static var lastSampleMB: UInt64 = 0

    /// 当前物理内存占用（字节）。
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let mb = footprintBytes() / 1_048_576
            // 内存采样写诊断日志；快速增长（>300MB/2s）标记出来，便于复盘
            let delta = Int64(mb) - Int64(lastSampleMB)
            if delta > 300 {
                Diagnostics.log("⚠️ 内存快速增长 +\(delta)MB（采样间隔 2s）")
            } else {
                Diagnostics.log("内存采样")
            }
            lastSampleMB = mb

            if mb >= hardLimitMB {
                Diagnostics.log("‼️ 超过硬上限 \(hardLimitMB)MB，主动退出以保护系统")
                NSLog("[MemoryGuard] %lluMB 超过硬上限，主动退出", mb)
                exit(137)  // 主动退出，避免吃满内存触发系统级 OOM 连锁
            } else if mb >= softLimitMB {
                if !warned {
                    warned = true
                    Diagnostics.log("⚠️ 越过软阈值 \(softLimitMB)MB，清理高亮缓存")
                }
                MainActor.assumeIsolated { DiffHighlighter.invalidate() }
            } else {
                warned = false
            }
        }
    }
}

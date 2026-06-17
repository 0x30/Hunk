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
    private static let hardLimitMB: UInt64 = 2500

    private static var timer: Timer?
    private static var warned = false
    /// 上次采样的内存，用于检测快速增长
    private static var lastSampleMB: UInt64 = 0
    /// 已抓过「进行中」快照，避免每 2s 重复 dump（覆盖写，只留最近一张）
    private static var grewDumped = false

    /// 当前内存占用（字节）：取 phys_footprint 与 RSS(resident_size) 的较大值。
    /// 关键：图形/图层内存（CoreAnimation 图层、IOSurface、GPU 纹理）只体现在 RSS，
    /// 不计入 phys_footprint。此前只看 phys_footprint，导致渲染层内存暴涨（RSS 已 7GB+
    /// 而 phys_footprint 仍 80MB）时看门狗完全失效、拦不住。现在用两者最大值。
    static func footprintBytes() -> UInt64 {
        var phys: UInt64 = 0
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let vmKr = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        if vmKr == KERN_SUCCESS { phys = vmInfo.phys_footprint }

        var resident: UInt64 = 0
        var basic = mach_task_basic_info()
        var bCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let bKr = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(bCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &bCount)
            }
        }
        if bKr == KERN_SUCCESS { resident = basic.resident_size }

        return max(phys, resident)
    }

    static func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let mb = footprintBytes() / 1_048_576
            // 内存采样写诊断日志；快速增长（>300MB/2s）标记出来，便于复盘
            let delta = Int64(mb) - Int64(lastSampleMB)
            if delta > 300 {
                Diagnostics.log("⚠️ 内存快速增长 +\(delta)MB（采样间隔 2s）")
                // 暴涨「进行中」就抓一张分区快照：和退出时那张对比，即可看出
                // 这 1~2 秒里涨的是哪个区（MALLOC 堆 / IOSurface / 图层）。只抓一次。
                if !grewDumped {
                    grewDumped = true
                    dumpVmmapSummary(to: "/tmp/hunk_vmmap_grow.txt")
                    // heap 按对象类型聚合，直接看出 GB 级堆里堆的是什么（String/Array/
                    // AttributedString/自定义类）。在「刚开始涨」时抓最安全（内存尚低）。
                    dumpHeap(to: "/tmp/hunk_heap_grow.txt")
                    Diagnostics.log("已抓进行中分区+堆快照 → /tmp/hunk_vmmap_grow.txt /tmp/hunk_heap_grow.txt")
                }
            } else {
                Diagnostics.log("内存采样")
                if mb < softLimitMB { grewDumped = false }  // 回落到安全区后，允许下次暴涨再抓
            }
            lastSampleMB = mb

            if mb >= hardLimitMB {
                Diagnostics.log("‼️ 超过硬上限 \(hardLimitMB)MB，dump 内存分区+堆后主动退出")
                NSLog("[MemoryGuard] %lluMB 超过硬上限，主动退出", mb)
                // 退出前 dump 自己的内存分区，定位 GB 级内存堆在哪个区（IOSurface/图层/MALLOC）
                dumpVmmapSummary(to: "/tmp/hunk_vmmap_exit.txt")
                // 暴涨太突然、没在 grow 阶段抓到堆时，退出前补一张——确保「杀死前」
                // 一定知道堆里是什么。已抓过就不重复（heap 很慢，避免拖到系统 OOM）。
                if !grewDumped {
                    Diagnostics.log("退出前补抓堆快照 → /tmp/hunk_heap_exit.txt")
                    dumpHeap(to: "/tmp/hunk_heap_exit.txt")
                }
                Diagnostics.log("dump 完成，退出码 137（堆快照见 /tmp/hunk_heap_*.txt）")
                exit(137)  // 主动退出，避免吃满内存触发系统级 OOM 连锁
            } else if mb >= softLimitMB {
                if !warned {
                    warned = true
                    Diagnostics.log("⚠️ 越过软阈值 \(softLimitMB)MB")
                }
            } else {
                warned = false
            }
        }
    }

    /// 把本进程的 vmmap 分区汇总写到 path（覆盖写）。退出 dump 与「进行中」快照共用。
    private static func dumpVmmapSummary(to path: String) {
        runTool("/usr/bin/vmmap", ["--summary", "\(getpid())"], to: path)
    }

    /// 把本进程的堆按对象类型聚合（heap --sortBySize）写到 path——直接看出 GB 级
    /// 堆里堆的是什么类型的对象（String / Array / AttributedString / 自定义类）。
    /// 比 vmmap 慢（要遍历所有对象），所以只在「刚开始涨」或退出兜底时抓一次。
    private static func dumpHeap(to path: String) {
        runTool("/usr/bin/heap", ["--sortBySize", "\(getpid())"], to: path)
    }

    /// 跑一个诊断工具、stdout 重定向到 path、同步等它结束。
    private static func runTool(_ tool: String, _ args: [String], to path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        if let out = FileHandle(forWritingAtPath: path)
            ?? { FileManager.default.createFile(atPath: path, contents: nil)
                 return FileHandle(forWritingAtPath: path) }() {
            task.standardOutput = out
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
            try? out.close()
        }
    }
}

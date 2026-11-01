//
//  CrashGuard.swift
//  MotoNav
//
//  v2.05 新增：崩溃现场记录
//
//  为什么需要它
//  ------------
//  这个 App 前两版出现「打开就闪退 / 点不开」，而在手机上拿不到任何信息，
//  只能靠猜 —— 猜错一次就多浪费一个版本。这里装两个钩子，出问题时
//  直接把原因写进沙箱 Documents/startup.log（「文件」App → 骑士地图 可读）：
//
//    · NSException  —— Objective-C 异常（UIKit / MapKit / SwiftUI 内部抛的）
//    · signal       —— Swift 运行时错误（数组越界、强制解包、fatalError 都是 SIGTRAP）
//
//  写文件路径固定、格式固定，用户截图就能定位，不需要连电脑。
//
//  安全性（这段别随便改）
//  --------------------
//  signal handler 里绝不能做堆分配、不能调 Foundation（会二次崩溃）。
//  只允许调用 async-signal-safe 的 open / write / close。
//  另外 StartupLog 是「整文件原子重写」，会把旧的 fd 指向已删除的 inode，
//  所以 handler 里每次自己 open 一次，而不是复用 install 时打开的 fd。
//

import Foundation
import UIKit

/// 日志文件路径的 C 字符串（strdup 出来的，进程生命周期内有效）
private var gCrashPath: UnsafeMutablePointer<CChar>?

/// 严格 async-signal-safe：只用 open / write / close
private func motonavSignalHandler(_ sig: Int32) {
    var fd: Int32 = -1
    if let p = gCrashPath {
        fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }
    guard fd >= 0 else { _exit(1) }

    switch sig {
    case SIGABRT:
        _ = write(fd, "[崩溃] 信号 SIGABRT（异常终止 / 断言失败）\n", 47)
    case SIGTRAP:
        _ = write(fd, "[崩溃] 信号 SIGTRAP（Swift 致命错误：越界 / 强制解包 / fatalError）\n", 72)
    case SIGSEGV:
        _ = write(fd, "[崩溃] 信号 SIGSEGV（野指针 / 非法内存访问）\n", 51)
    case SIGBUS:
        _ = write(fd, "[崩溃] 信号 SIGBUS（内存对齐 / 非法地址）\n", 48)
    case SIGILL:
        _ = write(fd, "[崩溃] 信号 SIGILL（非法指令）\n", 40)
    case SIGFPE:
        _ = write(fd, "[崩溃] 信号 SIGFPE（算术错误）\n", 41)
    default:
        _ = write(fd, "[崩溃] 未知信号\n", 22)
    }
    close(fd)
    _exit(1)
}

enum CrashGuard {
    private static var installed = false

    /// 崩溃单独一个文件。
    ///
    /// 不能和 startup.log 共用：StartupLog 采用"整文件读取 → 追加 → 原子重写"，
    /// 崩溃瞬间正好有日志在排队时，原子重写会把信号处理函数刚写进去的崩溃行覆盖掉，
    /// 表现就是"真崩了却一条都没留下"。分开写才不会有这个竞态。
    static var crashFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("crash.log")
    }

    /// 在 didFinishLaunching 的第一行调用
    static func install() {
        guard !installed else { return }
        installed = true

        // 路径只取一次，转成 C 字符串常驻（handler 里要用，不能临时算）
        gCrashPath = strdup(crashFileURL.path)
        // 预建文件：FileHandle(forWritingTo:) 要求文件已存在，否则 NSException 那条路径会静默失败
        if !FileManager.default.fileExists(atPath: crashFileURL.path) {
            FileManager.default.createFile(
                atPath: crashFileURL.path,
                contents: Data("=== 骑士地图崩溃日志（出现 [崩溃] 行说明进程非正常退出）===\n".utf8))
        }

        // 1) Objective-C 异常：不在信号上下文，可以正常用 Foundation。
        //    注意：这个闭包必须是 @convention(c)，**不能引用任何 static 成员**
        //    （引用就等于捕获 self/元类型，编译直接报 "cannot be formed from a closure
        //    that captures context"），所以路径在这里原地算一遍。
        NSSetUncaughtExceptionHandler { ex in
            let head = "\n[崩溃] 未捕获异常 \(ex.name.rawValue)\n原因: \(ex.reason ?? "无")\n"
            let stack = ex.callStackSymbols.prefix(24).joined(separator: "\n")
            let text = head + "调用栈:\n" + stack + "\n"
            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("crash.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
            }
            // 此刻进程将死，用追加方式直接写，不用原子写
            if let d = text.data(using: .utf8),
               let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(d)
                try? fh.close()
            }
        }

        // 2) 信号：只接管真正代表"崩了"的几个，不碰 SIGTERM/SIGSTOP（系统正常杀进程时会发）
        for s in [SIGABRT, SIGTRAP, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(s, motonavSignalHandler)
        }
    }

    // MARK: - v2.05 启动心跳 + 主线程探针

    /// 后台线程定期打点，并在第 8 秒探测主线程是否还在跑。
    ///
    /// 用途：如果 startup.log 里停在某一步、又没有任何 [崩溃] 行，只有两种可能 ——
    ///   · 进程还活着，但主线程被死循环/死锁占住（心跳有、探针报 BLOCKED）
    ///   · 进程被系统静默杀掉（心跳到某一秒就断了，且没有 BLOCKED）
    /// 这一条能把"卡死"和"被杀"彻底分开，不用再猜。
    static func startHeartbeat() {
        // v2.08：点打得更密。上一版 1 秒一个点，而进程往往活不过 1 秒，
        // 等于什么都没留下；现在 0.3 秒一个，能看出"死在第几秒"。
        let marks: [Double] = [0.3, 0.8, 1.4, 2.0, 2.6, 3.2, 4.0, 6.0, 10.0, 16.0]
        for d in marks {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + d) {
                StartupLog.mark(String(format: "tick-%.1fs", d), "内存 \(memMB())MB")
            }
        }
        // 主线程探针：往主队列投一个任务，1.2 秒内没被执行 → 主线程卡死
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
            let flag = ProbeFlag()
            DispatchQueue.main.async {
                flag.ran = true
                StartupLog.mark("main-loop-alive", "8 秒时主线程仍在跑消息循环")
            }
            Thread.sleep(forTimeInterval: 1.2)
            if !flag.ran {
                StartupLog.mark("main-BLOCKED", "8 秒后主线程仍未执行排队任务，首屏卡死")
            }
        }
    }

    /// 当前进程占用内存（MB）。用来判断是不是被系统按内存超限杀掉（jetsam）。
    static func memMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }
}


/// 跨线程传一个 bool（只为诊断，不需要严格同步）
private final class ProbeFlag {
    var ran = false
}

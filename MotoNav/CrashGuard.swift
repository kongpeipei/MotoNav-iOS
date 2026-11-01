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

    /// 在 didFinishLaunching 的第一行调用
    static func install() {
        guard !installed else { return }
        installed = true

        // 路径只取一次，转成 C 字符串常驻（handler 里要用，不能临时算）
        gCrashPath = strdup(StartupLog.fileURL.path)

        // 1) Objective-C 异常：不在信号上下文，可以正常用 Foundation
        NSSetUncaughtExceptionHandler { ex in
            let head = "\n[崩溃] 未捕获异常 \(ex.name.rawValue)\n原因: \(ex.reason ?? "无")\n"
            let stack = ex.callStackSymbols.prefix(24).joined(separator: "\n")
            let text = head + "调用栈:\n" + stack + "\n"
            // 此刻进程将死，用追加方式直接写，不用原子写
            if let d = text.data(using: .utf8),
               let fh = try? FileHandle(forWritingTo: StartupLog.fileURL) {
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
        for (delay, name) in [(1.0, "alive-1s"), (3.0, "alive-3s"), (8.0, "alive-8s"), (16.0, "alive-16s")] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                StartupLog.mark(name)
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
}

/// 跨线程传一个 bool（只为诊断，不需要严格同步）
private final class ProbeFlag {
    var ran = false
}

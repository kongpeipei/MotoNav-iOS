//
//  DiagBoot.swift
//  MotoNav
//
//  v2.08 新增：启动自检（纯 UIKit 首屏 + SwiftUI 分阶段挂载）
//
//  为什么还要再做一个诊断版
//  ------------------------
//  v2.07 日志：
//      app-launch → model-ready → window-visible → cameras-loaded → body-enter
//      （没有 ui-ready、没有 app-active、没有 alive-1s，也没有任何 [崩溃] 行）
//
//  `alive-1s` 是后台线程在第 1 秒打的点，它都没出现，说明**进程活不过 1 秒**，
//  而且不是信号能捕到的崩溃（NSException / SIGTRAP 都会留下 [崩溃] 行）。
//  只剩两种可能：
//    · 系统在启动阶段直接 SIGKILL（签名校验、看门狗、内存超限）
//    · 主线程栈溢出，信号处理函数自己也跑不起来
//  这两种从日志上都看不出来，只能把启动拆成"纯 UIKit"和"SwiftUI"两段分别验证。
//
//  这一版做了什么
//  --------------
//  1. 先挂一个**不含 SwiftUI** 的纯 UIKit 页面（亮绿底 + 版本号 + 实时时钟 + 日志尾）。
//     只要它出现，就证明窗口、渲染、主线程循环全部正常，问题一定在 SwiftUI 那一侧；
//     如果它也不出现，那就是窗口/场景层，或者进程根本没活到那一步。
//  2. 1.5 秒后把根视图换成 SwiftUI：先挂一个极简 BootstrapView（只有文字），
//     再 2 秒后挂真正的 ContentView。三段各自打点。
//  3. ContentView.body 里插了 BodyProbe，能看出 body 求值走到第几个子视图。
//  4. 后台心跳改成 0.3/0.8/1.4/2.0/2.6/3.2/4/6/10/16 秒，并带上内存占用，
//     这样"死在第几秒、死前内存多少"都能直接读出来。
//

import SwiftUI
import UIKit

// MARK: - 纯 UIKit 首屏

/// 不含 SwiftUI 的启动页。
/// 目的单一：验证"窗口能不能显示、主线程循环是否在跑"。
/// 页面上有实时时钟——时钟还在跳就是主线程活着，冻住就是卡死。
final class DiagRootController: UIViewController {
    private let clock = UILabel()
    private let tailLabel = UILabel()
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        StartupLog.mark("diag-vc-loaded")

        view.backgroundColor = UIColor(red: 0.06, green: 0.55, blue: 0.32, alpha: 1)

        let title = UILabel()
        title.text = "骑士地图 启动自检"
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = .white
        title.textAlignment = .center

        let sub = UILabel()
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        sub.text = "v\(ver) (\(build)) · 窗口与主线程正常"
        sub.font = .systemFont(ofSize: 15, weight: .medium)
        sub.textColor = UIColor.white.withAlphaComponent(0.9)
        sub.textAlignment = .center
        sub.numberOfLines = 0

        clock.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        clock.textColor = .white
        clock.textAlignment = .center
        clock.text = "--:--:--"

        let hint = UILabel()
        hint.text = "2 秒后自动进入地图界面"
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = UIColor.white.withAlphaComponent(0.75)
        hint.textAlignment = .center

        tailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        tailLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        tailLabel.numberOfLines = 0
        tailLabel.text = StartupLog.tail(10)

        let stack = UIStackView(arrangedSubviews: [title, sub, clock, hint, tailLabel])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        // 这一行能显示出来，就说明不是黑屏：版本号 + 时钟在跳
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            self?.clock.text = f.string(from: Date())
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        StartupLog.mark("diag-vc-appeared", "纯 UIKit 首屏已上屏")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        StartupLog.markOnce("diag-vc-layout", "\(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }

    deinit { timer?.invalidate() }
}

// MARK: - SwiftUI 宿主（带生命周期打点）

final class MotoHost: UIHostingController<AnyView> {
    override func viewDidLoad() {
        super.viewDidLoad()
        StartupLog.mark("host-loaded")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        StartupLog.markOnce("host-will-appear")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        StartupLog.mark("host-appeared", "SwiftUI 宿主已上屏")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        StartupLog.markOnce("host-layout", "\(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }
}

// MARK: - 极简 SwiftUI 启动视图

/// 只放文字和时钟的 SwiftUI 视图。
/// 如果它上不了屏，而纯 UIKit 页面上得了，那就是 SwiftUI 渲染管线在这个环境下有问题；
/// 如果它上屏了、切到 ContentView 才死，那就锁定在 ContentView。
struct BootstrapView: View {
    @EnvironmentObject var model: AppModel
    @State private var showContent = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.16),
                                    Color(red: 0.10, green: 0.14, blue: 0.24)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            if showContent {
                ContentView()
                    .environmentObject(model)
                    .transition(.opacity)
            } else {
                VStack(spacing: 14) {
                    Text("骑士地图")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                    Text("SwiftUI 渲染正常，2 秒后加载主界面")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                    // 用 TimelineView 驱动数字跳动：屏幕上的时间还在走 = 渲染管线与主线程都活着。
                    // 一旦冻住，用户一眼就能看出来，也说明卡在这一层。
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        Text(Self.fmt.string(from: ctx.date))
                            .font(.system(size: 30, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                }
            }
        }
        .onAppear {
            StartupLog.mark("swiftui-appear", "BootstrapView 已上屏")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                StartupLog.mark("content-mount", "开始挂载 ContentView")
                withAnimation(.easeInOut(duration: 0.25)) { showContent = true }
            }
        }
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - body 分段探针

/// 插在 ContentView.body 的 ZStack 里，构造时就打点 —— 用来确认 body 求值走到第几段。
struct BodyProbe: View {
    init(_ key: String) { StartupLog.markOnce(key) }
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }
}

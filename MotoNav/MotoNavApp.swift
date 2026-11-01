//
//  MotoNavApp.swift
//  MotoNav
//
//  v2.07：从 SwiftUI App 生命周期改为 UIKit 生命周期（AppDelegate + UIWindow）
//
//  为什么改
//  --------
//  v2.06 的启动日志把问题指得很死：
//      app-launch → model-ready → cameras-loaded → body-enter，然后进程就没了，
//      全程没有 app-active，没有任何 [崩溃] 信号。
//
//  `applicationDidBecomeActive` 一次都没触发，意味着 UIScene 从未激活 —— 窗口没生效，
//  视图树自然渲染不出来，onAppear 也就永远不到（ui-ready 缺失）。这不是业务代码卡死，
//  而是 SwiftUI 的 App/Scene 生命周期在这台设备上没走通（第三方重签 + 系统版本组合下
//  已知会出现这类 scene 不激活的问题）。
//
//  所以这里退回最原始、最不依赖系统"自动装配"的方式：
//      AppDelegate 自己 new 一个 UIWindow，塞一个 UIHostingController 当根视图。
//  不再依赖 WindowGroup，也不再依赖 UIScene 配置（Info.plist 里的
//  UIApplicationSceneManifest 已同时移除），SwiftUI 只负责画界面。
//
//  这同时解释了 v2.03/v2.04 为什么"点不开"：当时删了 scene 声明，却仍在用
//  SwiftUI App 生命周期 —— 没有 scene 就没有 window，等于永远没有界面。
//

import SwiftUI
import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 先把崩溃钩子装上，之后哪一步炸了都会在 Documents/crash.log 留痕
        CrashGuard.install()
        CrashGuard.startHeartbeat()

        let bundle = Bundle.main
        let ver = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        StartupLog.mark("app-launch", "v\(ver) (\(build))")

        // 提前初始化共享模型，注册通知与定位
        _ = AppModel.shared
        StartupLog.mark("model-ready")

        // v2.08：先挂纯 UIKit 页面，确认窗口/渲染/主线程都正常，再换 SwiftUI。
        // 一上来就挂 SwiftUI 时，一旦它那边出问题就是黑屏，什么都看不到；
        // 先给一个必然能显示的 UIView，屏幕亮起来就知道走到哪一步了。
        // 启动次数计数：上一次没走到首屏（ui-ready 会把计数清零），这次就停在自检页手动载入，
        // 保证 App 任何时候都"打得开"，不会又变成一块黑屏。
        let ud = UserDefaults.standard
        let attempt = ud.integer(forKey: "motonav.bootAttempts") + 1
        ud.set(attempt, forKey: "motonav.bootAttempts")
        StartupLog.mark("boot-attempt", "第 \(attempt) 次")

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = UIColor(red: 0.06, green: 0.55, blue: 0.32, alpha: 1)
        let diag = DiagRootController()
        diag.onLoadUI = { [weak self] in self?.switchToSwiftUI() }
        diag.onLoadLite = { [weak self] in self?.switchToSwiftUI(lite: true) }
        win.rootViewController = diag
        win.makeKeyAndVisible()
        window = win
        StartupLog.mark("window-visible")

        // scene 状态单独记一笔：没有 scene 时窗口也可能"以为显示了其实没有"
        let scenes = UIApplication.shared.connectedScenes.count
        StartupLog.mark("scene-check", "scenes=\(scenes) state=\(UIApplication.shared.applicationState.rawValue)")

        if attempt <= 1 {
            // 第一次：正常自动进主界面（诊断探针全开）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.switchToSwiftUI()
            }
        } else if attempt == 2 {
            // 第二次：停在自检页，让用户能看清屏幕上的崩溃/日志再手动点
            StartupLog.mark("safe-hold", "上次启动未到首屏，停在自检页等手动载入")
        } else {
            // v2.10 第三次起：自动进**精简界面**，保证 App 至少能用；
            // 自检页上的「载入主界面」随时可以再试完整版
            StartupLog.mark("safe-hold", "已连续 \(attempt - 1) 次没到首屏，自动改用精简界面")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.switchToSwiftUI(lite: true)
            }
        }

        return true
    }

    /// 从纯 UIKit 首屏切到 SwiftUI（分两段：极简视图 → 真正主界面）
    /// - Parameter lite: v2.10 精简模式（只地图 + 一条搜索卡），主界面反复闪退时用它兜底
    private func switchToSwiftUI(lite: Bool = false) {
        guard let win = window else {
            StartupLog.mark("swap-no-window")
            return
        }
        StartupLog.markSync("swap-begin", lite ? "lite" : "full")
        let root = AnyView(BootstrapView(lite: lite).environmentObject(AppModel.shared))
        let host = MotoHost(rootView: root)
        win.rootViewController = host
        StartupLog.mark("swap-done")
    }

    /// 通过 motonav:// 链接直接规划路线（对应原来 SwiftUI 的 .onOpenURL）
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        AppModel.shared.handleRouteURL(url)
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        StartupLog.markOnce("app-active")
        // scene 可能晚于 didFinishLaunching 就绪，这里补一次窗口与场景的绑定信息
        StartupLog.markOnce("scene-active", "scenes=\(UIApplication.shared.connectedScenes.count)")
    }

    func applicationWillResignActive(_ application: UIApplication) {
        StartupLog.mark("app-resign-active")
    }

    // v1.81.4 导航中切到后台：播报"骑士地图继续为您导航"，导航与语音提醒继续后台运行
    //（Info.plist UIBackgroundModes 含 location+audio）；用户从后台清除 App 后停止
    func applicationDidEnterBackground(_ application: UIApplication) {
        StartupLog.mark("app-background")
        let m = AppModel.shared
        if m.navigating {
            m.speak("骑士地图继续为您导航")
        }
    }
}

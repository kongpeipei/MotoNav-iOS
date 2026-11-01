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

@main
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

        // 手动建窗口：这是整条启动链最关键的一步
        let win = UIWindow(frame: UIScreen.main.bounds)
        let host = UIHostingController(rootView: ContentView().environmentObject(AppModel.shared))
        win.rootViewController = host
        win.makeKeyAndVisible()
        window = win
        StartupLog.mark("window-visible")

        return true
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
    }

    // v1.81.4 导航中切到后台：播报"骑士地图继续为您导航"，导航与语音提醒继续后台运行
    //（Info.plist UIBackgroundModes 含 location+audio）；用户从后台清除 App 后停止
    func applicationDidEnterBackground(_ application: UIApplication) {
        let m = AppModel.shared
        if m.navigating {
            m.speak("骑士地图继续为您导航")
        }
    }
}

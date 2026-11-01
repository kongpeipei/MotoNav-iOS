//
//  MotoNavApp.swift
//  MotoNav
//
//  v2.12：清理启动诊断代码，回到最简启动链路。
//
//  背景
//  ----
//  v2.07~v2.11 为定位"点开就闪退"问题，临时加过一整套诊断设施：
//  自检页（纯 UIKit 绿屏）、启动日志、崩溃钩子、心跳、body 探针、精简界面兜底。
//  v2.11 用 AnyView 截断视图类型嵌套后问题已解决，这些设施全部移除。
//
//  启动方式保持不变：仍然由 AppDelegate 自己创建 UIWindow，
//  不依赖 SwiftUI App/Scene 生命周期（在这台设备 + 第三方重签组合下曾出现 scene 不激活）。
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
        let win = UIWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = .systemBackground
        win.rootViewController = UIHostingController(
            rootView: ContentView().environmentObject(AppModel.shared)
        )
        win.makeKeyAndVisible()
        window = win
        return true
    }

    /// 通过 motonav:// 链接直接规划路线
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        AppModel.shared.handleRouteURL(url)
        return true
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

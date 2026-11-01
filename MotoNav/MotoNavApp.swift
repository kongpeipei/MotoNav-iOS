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
        installSplash(on: win)
        return true
    }

    /// v2.13 启动闪屏改到 UIKit 层。
    ///
    /// 旧做法是放在 ContentView 的 ZStack 里，靠 `onAppear` 起一个 Task 在 1 秒后置 false。
    /// 那个 Task 需要主线程空闲才能跑；一旦视图树在重算，它永远排不上队，
    /// 表现就是「黑底 + 骑士地图四个字，一直不进主界面」。
    /// 现在改成盖在 window 上的一个 UIView，用 UIView.animate 淡出：
    /// 动画由 CoreAnimation 驱动，不依赖 SwiftUI 的任何状态更新，2.25 秒后必定消失（v2.24）。
    private func installSplash(on win: UIWindow) {
        let splash = UIView(frame: win.bounds)
        splash.backgroundColor = .black
        splash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // 不拦截触摸：底下的主界面可以先加载、可以先点
        splash.isUserInteractionEnabled = false

        // v2.24 标题字号 48 → 64（更醒目），仍用同一套楷体
        let titleSize: CGFloat = 64
        let label = UILabel()
        label.text = "骑士地图"
        label.textColor = .white
        // 楷体：不同系统版本 PostScript 名不一样，逐个兜底，最后用系统粗体
        label.font = UIFont(name: "STKaitiSC-Regular", size: titleSize)
            ?? UIFont(name: "Kaiti SC", size: titleSize)
            ?? UIFont.systemFont(ofSize: titleSize, weight: .bold)
        label.sizeToFit()
        label.center = CGPoint(x: splash.bounds.midX, y: splash.bounds.midY)
        label.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin,
                                 .flexibleLeftMargin, .flexibleRightMargin]
        splash.addSubview(label)

        // v2.24 右下角版本号：与标题同字体（楷体），字号按标题的比例取小一号，
        // 颜色略淡（不抢标题），位置离屏幕右下角各留 24pt 安全边
        let versionLabel = UILabel()
        versionLabel.text = "v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.24")
        versionLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        versionLabel.font = UIFont(name: "STKaitiSC-Regular", size: titleSize * 0.42)
            ?? UIFont(name: "Kaiti SC", size: titleSize * 0.42)
            ?? UIFont.systemFont(ofSize: titleSize * 0.42, weight: .medium)
        versionLabel.sizeToFit()
        versionLabel.textAlignment = .right
        versionLabel.frame.origin = CGPoint(
            x: splash.bounds.width - versionLabel.bounds.width - 24,
            y: splash.bounds.height - versionLabel.bounds.height - 24)
        versionLabel.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
        splash.addSubview(versionLabel)

        win.addSubview(splash)

        // v2.24 启动动画延长 1 秒：原来 delay 0.9 + 淡出 0.35 ≈ 1.25 秒，
        // 现在 delay 1.9 + 淡出 0.35 ≈ 2.25 秒。
        // 淡出仍由 CoreAnimation 驱动，不依赖 SwiftUI 状态更新，到点必定消失。
        UIView.animate(withDuration: 0.35, delay: 1.9, options: [.curveEaseOut]) {
            splash.alpha = 0
        } completion: { _ in
            splash.removeFromSuperview()
        }
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

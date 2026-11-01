import SwiftUI

@main
struct MotoNavApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(AppModel.shared)
                .onOpenURL { url in
                    AppModel.shared.handleRouteURL(url)
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // v2.05：先把崩溃钩子装上，再干别的。这样之后无论哪一步炸了，
        // 都会在 Documents/startup.log 里留下一行「[崩溃] ...」，不用连电脑取日志。
        CrashGuard.install()
        CrashGuard.startHeartbeat()

        // v2.03：启动埋点。能打到这一行说明进程已经起来、签名校验通过，
        // 后面若闪退就不是签名问题，而是初始化阶段（日志可在「文件」App 里查看）。
        let bundle = Bundle.main
        let ver = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        StartupLog.mark("app-launch", "v\(ver) (\(build))")
        // 提前初始化共享模型，注册通知与定位
        _ = AppModel.shared
        StartupLog.mark("model-ready")
        return true
    }

    // v2.05 诊断：didBecomeActive 是"窗口已经建好、App 进入前台"的信号。
    // 如果 startup.log 里连这一条都没有，说明 UIScene/窗口根本没建立（配置问题）；
    // 有这一条却没有 ui-ready，说明窗口有了但首屏视图没渲染出来（视图/布局问题）。
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

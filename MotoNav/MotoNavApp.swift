import SwiftUI
import AMapFoundationKit

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
        // v1.68 B档：高德 iOS 地图 SDK 初始化（必须在 MAMapView 创建前设置 Key）
        AMapServices.shared().apiKey = "6fd752bc12caa258f066729617db0066"
        AMapServices.shared().enableHTTPS = true
        // 提前初始化共享模型，注册通知与定位
        _ = AppModel.shared
        return true
    }
}

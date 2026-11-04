import SwiftUI

@main
struct CameraGuardApp: App {
    @StateObject private var engine = AlertEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .task { engine.start() } // 打开即开始监听（后台持续定位+语音播报）
        }
    }
}

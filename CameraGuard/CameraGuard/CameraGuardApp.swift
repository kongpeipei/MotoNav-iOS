import SwiftUI

@main
struct CameraGuardApp: App {
    @StateObject private var engine = AlertEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .task { engine.start() } // 打开即开始监听（后台持续定位+语音播报）
                // v1.24：后台超时自动结束灵动岛 / 回前台恢复
                .onChange(of: scenePhase) { _, newPhase in
                    engine.handleScenePhase(newPhase)
                }
        }
    }
}

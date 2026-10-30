import WidgetKit
import SwiftUI
import ActivityKit

/// 违拍提醒 Live Activity（灵动岛 + 锁屏）
/// 与主 App 内 ActivityModels.swift 中结构完全一致（ActivityKit 按 Bundle ID 匹配）
struct MotoNavAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var poiName: String
        var poiType: String
        var distanceM: Int
    }
    var destName: String
}

struct MotoNavLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MotoNavAttributes.self) { context in
            // 锁屏 / 通知中心样式
            HStack(spacing: 12) {
                Image(systemName: "camera.viewfinder")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                    .frame(width: 42, height: 42)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("前方 \(context.state.distanceM) 米 · \(context.state.poiType)")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(context.state.poiName) · 去往 \(context.attributes.destName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.75))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "camera.viewfinder")
                        .font(.title2)
                        .foregroundStyle(.yellow)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.distanceM)米")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("前方\(context.state.poiName) · \(context.state.poiType)")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "camera.viewfinder")
                    .foregroundStyle(.yellow)
            } compactTrailing: {
                Text("\(context.state.distanceM)米")
                    .font(.caption2)
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: "camera.viewfinder")
                    .foregroundStyle(.yellow)
            }
        }
    }
}

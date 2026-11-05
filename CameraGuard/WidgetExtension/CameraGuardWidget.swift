import WidgetKit
import SwiftUI
import ActivityKit

/// v1.9 灵动岛 / Live Activity 展示。
/// 与 App 内 CameraGuardActivityAttributes 保持同名同字段，ActivityKit 据此匹配。
struct CameraGuardActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "cruising" 巡航（绿色） / "warning" 预警（红色）
        var phase: String
        var title: String
        var detail: String
        var distanceM: Int
    }
    var name: String = "电子眼卫士"
}

/// 灵动岛实时活动组件：巡航时绿点 + "电子眼"；接近抓拍点时红色三角 + 球内米数
struct CameraGuardActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CameraGuardActivityAttributes.self) { context in
            LiveActivityCard(context: context)
        } dynamicIsland: { context in
            let warning = context.state.phase == "warning"
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: warning ? "exclamationmark.triangle.fill" : "scope")
                        .font(.headline)
                        .foregroundStyle(warning ? .red : .green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // v1.27：无有效距离时不再显示"--"，改显 scope 图标
                    if context.state.distanceM > 0 {
                        Text("\(context.state.distanceM)m")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(warning ? .red : .green)
                    } else {
                        Image(systemName: "scope")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .foregroundStyle(warning ? .red : .primary) // v1.25 预警全红
                        Text(context.state.detail)
                            .font(.footnote)
                            .foregroundStyle(warning ? .red : .secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: warning ? "exclamationmark.triangle.fill" : "scope")
                    .foregroundStyle(warning ? .red : .green)
            } compactTrailing: {
                // v1.27：无有效距离时不再显示"--"，改显 scope 图标
                if context.state.distanceM > 0 {
                    Text("\(context.state.distanceM)m")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(warning ? .red : .green)
                } else {
                    Image(systemName: "scope")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } minimal: {
                Image(systemName: warning ? "exclamationmark.triangle.fill" : "scope")
                    .foregroundStyle(warning ? .red : .green)
            }
        }
    }
}

/// 锁屏 / 展开卡片样式：绿=巡航，红=预警+距离
struct LiveActivityCard: View {
    let context: ActivityViewContext<CameraGuardActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: context.state.phase == "warning"
                  ? "exclamationmark.triangle.fill" : "scope")
                .font(.title2)
                .foregroundStyle(context.state.phase == "warning" ? .red : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.title)
                    .font(.headline)
                    .foregroundStyle(context.state.phase == "warning" ? .red : .primary) // v1.25 预警全红
                Text(context.state.detail)
                    .font(.subheadline)
                    .foregroundStyle(context.state.phase == "warning" ? .red : .secondary)
            }
            Spacer()
            // v1.27：无有效距离时不再显示"--"，改显 scope 图标
            if context.state.distanceM > 0 {
                Text("\(context.state.distanceM) 米")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(context.state.phase == "warning" ? .red : .green)
            } else {
                Image(systemName: "scope")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }
}

@main
struct CameraGuardWidgetBundle: WidgetBundle {
    var body: some Widget {
        CameraGuardActivityWidget()
    }
}

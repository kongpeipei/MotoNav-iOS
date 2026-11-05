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
        /// v1.28 抓拍类型图标 key（PoiType.rawValue，"" = 不显示）
        var icon: String
    }
    var name: String = "电子眼卫士"
}

// MARK: - v1.28 灵动岛中间抓拍类型图标（自绘，高德同款风格）

/// 抓拍类型图标：按 PoiType.rawValue 选择，巡航绿 / 预警红
@ViewBuilder
func poiTypeIconView(key: String, color: Color) -> some View {
    let s = StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
    switch key {
    case "RED_LIGHT": // 红绿灯：竖排三圆
        ZStack {
            RoundedRectangle(cornerRadius: 2.5)
                .stroke(color, style: s)
            VStack(spacing: 1.8) {
                Circle().fill(color).frame(width: 3.8, height: 3.8)
                Circle().fill(color.opacity(0.4)).frame(width: 3.8, height: 3.8)
                Circle().fill(color).frame(width: 3.8, height: 3.8)
            }
        }
        .frame(width: 20, height: 20)
    case "SPEED": // 超速：速度表
        ZStack {
            ArcShape().stroke(color, style: s)
            Path { p in
                p.move(to: CGPoint(x: 10, y: 13))
                p.addLine(to: CGPoint(x: 14.5, y: 6.5))
            }.stroke(color, style: s)
            Path { p in
                p.move(to: CGPoint(x: 10, y: 13))
                p.addLine(to: CGPoint(x: 6.5, y: 8.5))
            }.stroke(color.opacity(0.45), style: s)
            Circle().fill(color).frame(width: 2.6, height: 2.6)
                .offset(x: 0, y: 1)
        }
        .frame(width: 20, height: 20)
    case "LANE": // 压线：车道+变道箭头
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .stroke(color, style: s)
            VStack(spacing: 0) {
                DashedLine().stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [2.4]))
                    .frame(height: 3)
                Path { p in
                    p.move(to: CGPoint(x: 3.5, y: 6.5))
                    p.addLine(to: CGPoint(x: 8.5, y: 10))
                    p.addLine(to: CGPoint(x: 3.5, y: 13.5))
                }.stroke(color, style: s)
                DashedLine().stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [2.4]))
                    .frame(height: 3)
            }
            .padding(.vertical, 3)
        }
        .frame(width: 20, height: 20)
    case "HELMET": // 摩托车整车（不戴头盔）
        ZStack {
            Circle().stroke(color, style: s).frame(width: 9, height: 9)
                .offset(x: -3.8, y: 5)
            Circle().stroke(color, style: s).frame(width: 9, height: 9)
                .offset(x: 4.2, y: 5)
            Path { p in
                p.move(to: CGPoint(x: 4.4, y: 10.6))
                p.addCurve(to: CGPoint(x: 9.4, y: 5.6), control1: CGPoint(x: 4.4, y: 7.4), control2: CGPoint(x: 6.6, y: 5.6))
                p.addLine(to: CGPoint(x: 13, y: 7.6))
                p.addLine(to: CGPoint(x: 14.4, y: 10.6))
            }.stroke(color, style: s)
            Path { p in
                p.move(to: CGPoint(x: 9.4, y: 5.6))
                p.addLine(to: CGPoint(x: 9.4, y: 2.8))
            }.stroke(color, style: s)
            Path { p in
                p.move(to: CGPoint(x: 6, y: 2.8))
                p.addLine(to: CGPoint(x: 12.4, y: 1.6))
            }.stroke(color, style: s)
            Circle().fill(color.opacity(0.85)).frame(width: 4.2, height: 4.2)
                .offset(x: 4.2, y: -5.4)
        }
        .frame(width: 20, height: 20)
    case "RESTRICTION": // 限行/禁摩：禁行圈
        ZStack {
            Circle().stroke(color, style: s)
            Path { p in
                p.move(to: CGPoint(x: 5.8, y: 5.8))
                p.addLine(to: CGPoint(x: 14.2, y: 14.2))
            }.stroke(color, style: s)
            Circle().fill(color).frame(width: 2.4, height: 2.4)
        }
        .frame(width: 20, height: 20)
    case "CUSTOM": // 自定义：定位图钉+感叹号
        ZStack {
            PinShape().stroke(color, style: s)
            Circle().stroke(color, style: s).frame(width: 6.6, height: 6.6)
            Path { p in
                p.move(to: CGPoint(x: 10, y: 4.6))
                p.addLine(to: CGPoint(x: 10, y: 7.2))
            }.stroke(color, style: s)
            Circle().fill(color).frame(width: 1.7, height: 1.7)
                .offset(x: 0, y: 2.6)
        }
        .frame(width: 20, height: 20)
    default:
        EmptyView()
    }
}

/// 速度表半圆弧
private struct ArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.maxY),
                 radius: rect.width * 0.42,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        return p
    }
}

/// 压线虚线（横线）
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 1, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.midY))
        return p
    }
}

/// 自定义图钉
private struct PinShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: w * 0.5, y: h * 0.04))
        p.addCurve(to: CGPoint(x: w * 0.14, y: h * 0.42),
                   control1: CGPoint(x: w * 0.24, y: h * 0.04), control2: CGPoint(x: w * 0.14, y: h * 0.2))
        p.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.98),
                   control1: CGPoint(x: w * 0.14, y: h * 0.58), control2: CGPoint(x: w * 0.32, y: h * 0.82))
        p.addCurve(to: CGPoint(x: w * 0.86, y: h * 0.42),
                   control1: CGPoint(x: w * 0.68, y: h * 0.82), control2: CGPoint(x: w * 0.86, y: h * 0.58))
        p.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.04),
                   control1: CGPoint(x: w * 0.86, y: h * 0.2), control2: CGPoint(x: w * 0.76, y: h * 0.04))
        p.closeSubpath()
        return p
    }
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
                        HStack(spacing: 5) {
                            // v1.28：灵动岛中间显示抓拍类型图标（巡航绿/预警红）
                            if !context.state.icon.isEmpty {
                                poiTypeIconView(key: context.state.icon,
                                                color: warning ? .red : .green)
                                    .frame(width: 18, height: 18)
                            }
                            Text(context.state.title)
                                .font(.headline)
                                .foregroundStyle(warning ? .red : .primary) // v1.25 预警全红
                        }
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
                HStack(spacing: 4) {
                    // v1.28：锁屏卡 title 前也显示抓拍类型图标
                    if !context.state.icon.isEmpty {
                        poiTypeIconView(key: context.state.icon,
                                        color: context.state.phase == "warning" ? .red : .green)
                            .frame(width: 16, height: 16)
                    }
                    Text(context.state.title)
                        .font(.headline)
                        .foregroundStyle(context.state.phase == "warning" ? .red : .primary) // v1.25 预警全红
                }
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

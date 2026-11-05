import WidgetKit
import SwiftUI
import ActivityKit

/// 机车地图 Live Activity（灵动岛 + 锁屏）
/// 与主 App 内 ActivityModels.swift 中结构完全一致（ActivityKit 按 Bundle ID 匹配）
struct MotoNavAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "cruising" 巡航（绿色） / "warning" 预警（红色）
        var phase: String
        var title: String
        var detail: String
        /// 距最近点位距离（米），巡航态实时更新
        var distanceM: Int
        /// 点位类型图标 key（PoiType.rawValue，"" = 不显示）
        var icon: String
    }
    var destName: String
}

// MARK: - v2.31 点位类型图标（自绘，与 CameraGuard 同款；含用户指定揭面盔剪影）

/// 点位类型图标：按 PoiType.rawValue 选择，巡航绿 / 预警红
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
    case "HELMET": // 揭面盔剪影（用户指定图标，轮廓提取自参考图）
        HelmetShape().stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
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
    case "CUSTOM": // 自定义：直接显示文字
        Text("自定义")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .fixedSize()
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

/// 揭面盔剪影：外轮廓 + 面罩弧线（用户指定图标）
private struct HelmetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        let outer: [(CGFloat, CGFloat)] = [
            (0.7380, 0.4860), (0.7380, 0.5000), (0.7380,
            0.5140), (0.7400, 0.5300), (0.7400, 0.5440),
            (0.7400, 0.5600), (0.7400, 0.5780), (0.7380,
            0.5940), (0.6880, 0.5820), (0.7080, 0.6120),
            (0.6320, 0.5680), (0.6480, 0.5960), (0.6280,
            0.5900), (0.7080, 0.7080), (0.5800, 0.5540),
            (0.5700, 0.5480), (0.5780, 0.5760), (0.5560,
            0.5400), (0.6040, 0.7020), (0.5540, 0.5660),
            (0.5680, 0.6820), (0.5540, 0.6740), (0.5400,
            0.6740), (0.5280, 0.6720), (0.5140, 0.6700),
            (0.5280, 0.5200), (0.5200, 0.5420), (0.4760,
            0.6640), (0.5220, 0.5160), (0.4500, 0.6600),
            (0.4360, 0.6560), (0.5040, 0.5300), (0.4060,
            0.6480), (0.3920, 0.6440), (0.3760, 0.6400),
            (0.5100, 0.5060), (0.4900, 0.5180), (0.3220,
            0.6180), (0.3040, 0.6080), (0.2860, 0.5960),
            (0.2700, 0.5820), (0.2640, 0.5640), (0.2680,
            0.5420), (0.2700, 0.5240), (0.2640, 0.5040),
            (0.2600, 0.4860), (0.2620, 0.4660), (0.2640,
            0.4480), (0.2680, 0.4300), (0.2700, 0.4100),
            (0.2640, 0.3880), (0.2640, 0.3660), (0.4320,
            0.4320), (0.3080, 0.3440), (0.4320, 0.4120),
            (0.4360, 0.4040), (0.3480, 0.3080), (0.4620,
            0.4060), (0.3800, 0.2880), (0.4760, 0.4000),
            (0.4720, 0.3780), (0.4300, 0.2720), (0.4460,
            0.2700), (0.4640, 0.2700), (0.4800, 0.2700),
            (0.4960, 0.2700), (0.5120, 0.2720), (0.5300,
            0.3760), (0.5380, 0.3780), (0.5560, 0.2800),
            (0.5700, 0.2820), (0.5600, 0.3820), (0.5680,
            0.3820), (0.6100, 0.2980), (0.5840, 0.3840),
            (0.5920, 0.3860), (0.6020, 0.3860), (0.6560,
            0.3320), (0.6220, 0.3880), (0.6360, 0.3880),
            (0.6820, 0.3620), (0.6660, 0.3900), (0.6880,
            0.3900), (0.6740, 0.4120), (0.7000, 0.4120),
            (0.7260, 0.4160), (0.7300, 0.4300), (0.7340,
            0.4440), (0.7340, 0.4580), (0.7360, 0.4720),
        ]
        p.move(to: CGPoint(x: outer[0].0 * w, y: outer[0].1 * h))
        for pt in outer.dropFirst() {
            p.addLine(to: CGPoint(x: pt.0 * w, y: pt.1 * h))
        }
        p.closeSubpath()
        let visor: [(CGFloat, CGFloat)] = [
            (0.5020, 0.5260), (0.3900, 0.6460), (0.3740,
            0.6420), (0.3580, 0.6360), (0.3400, 0.6280),
            (0.3220, 0.6200), (0.3040, 0.6100), (0.2860,
            0.5980), (0.2680, 0.5840), (0.4780, 0.5040),
            (0.2640, 0.5460), (0.2680, 0.5260), (0.2620,
            0.5080), (0.2580, 0.4880), (0.2580, 0.4700),
            (0.4560, 0.4780), (0.2660, 0.4320), (0.4460,
            0.4640), (0.4420, 0.4560), (0.2600, 0.3680),
            (0.2760, 0.3520), (0.3040, 0.3460), (0.3160,
            0.3320), (0.4520, 0.4220), (0.4400, 0.4000),
            (0.3600, 0.2980), (0.4640, 0.4020), (0.3900,
            0.2800), (0.4080, 0.2740), (0.4860, 0.3960),
            (0.4420, 0.2680), (0.4600, 0.2680), (0.5040,
            0.3760), (0.4920, 0.2680), (0.5200, 0.3780),
            (0.5240, 0.2700), (0.5400, 0.2720), (0.5540,
            0.2760), (0.5680, 0.2800), (0.5820, 0.2840),
            (0.5960, 0.2900), (0.6100, 0.2960), (0.6220,
            0.3020), (0.6340, 0.3100), (0.6460, 0.3180),
            (0.5960, 0.4060), (0.6040, 0.4080), (0.6760,
            0.3500), (0.6840, 0.3600), (0.6400, 0.4100),
            (0.6860, 0.3920), (0.6800, 0.4100), (0.7080,
            0.4100), (0.7300, 0.4160), (0.7340, 0.4300),
            (0.7360, 0.4460), (0.7380, 0.4600), (0.7380,
            0.4740), (0.7400, 0.4900), (0.7400, 0.5040),
            (0.7420, 0.5180), (0.7420, 0.5340), (0.7420,
            0.5480), (0.7420, 0.5660), (0.7420, 0.5820),
            (0.7340, 0.5960), (0.6840, 0.5840), (0.6520,
            0.5760), (0.7360, 0.6600), (0.6120, 0.5660),
            (0.7180, 0.6960), (0.7060, 0.7120), (0.5920,
            0.5780), (0.5820, 0.5760), (0.5720, 0.5720),
            (0.6220, 0.7120), (0.5560, 0.5640), (0.5820,
            0.6920), (0.5660, 0.6840), (0.5380, 0.5520),
            (0.5380, 0.6760), (0.5260, 0.6740), (0.5260,
            0.5440), (0.5220, 0.5420), (0.4860, 0.6700),
            (0.5220, 0.5180), (0.4600, 0.6640), (0.4460,
            0.6620), (0.4340, 0.6580), (0.4200, 0.6560),
        ]
        p.move(to: CGPoint(x: visor[0].0 * w, y: visor[0].1 * h))
        for pt in visor.dropFirst() {
            p.addLine(to: CGPoint(x: pt.0 * w, y: pt.1 * h))
        }
        return p
    }
}

private struct DashedLine: Shape {
    /// 压线虚线（横线）
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 1, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.midY))
        return p
    }
}

/// 锁屏 / 通知中心样式（v2.31 同 CameraGuard：预警红/巡航绿 + 图标 + 距离数字）
private struct LiveActivityCard: View {
    let context: ActivityViewContext<MotoNavAttributes>
    var body: some View {
        let warning = context.state.phase == "warning"
        HStack(spacing: 12) {
            if context.state.icon.isEmpty {
                HelmetShape().stroke(warning ? Color.red : Color.green,
                                     style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            } else {
                poiTypeIconView(key: context.state.icon, color: warning ? .red : .green)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.title)
                    .font(.headline)
                    .foregroundStyle(warning ? .red : .primary)
                Text(context.state.detail)
                    .font(.caption)
                    .foregroundStyle(warning ? .red : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(context.state.distanceM > 0 ? "\(context.state.distanceM)m" : "0m")
                .font(.headline.monospacedDigit())
                .foregroundStyle(warning ? .red : .green)
        }
        .padding()
        .activityBackgroundTint(Color.black.opacity(0.75))
        .activitySystemActionForegroundColor(.white)
    }
}

struct MotoNavLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MotoNavAttributes.self) { context in
            LiveActivityCard(context: context)
        } dynamicIsland: { context in
            let warning = context.state.phase == "warning"
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // v2.31 头盔剪影（无点位类型时）/ 点位类型图标，预警红/巡航绿
                    if context.state.icon.isEmpty {
                        HelmetShape().stroke(warning ? Color.red : Color.green,
                                             style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .frame(width: 20, height: 20)
                    } else {
                        poiTypeIconView(key: context.state.icon, color: warning ? .red : .green)
                            .frame(width: 20, height: 20)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // 右侧一直显示距离数字，颜色随巡航绿/预警红变化
                    Text(context.state.distanceM > 0 ? "\(context.state.distanceM)m" : "0m")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(warning ? .red : .green)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .foregroundStyle(warning ? .red : .primary)
                        Text(context.state.detail)
                            .font(.footnote)
                            .foregroundStyle(warning ? .red : .secondary)
                    }
                }
            } compactLeading: {
                if context.state.icon.isEmpty {
                    HelmetShape().stroke(warning ? Color.red : Color.green,
                                         style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 14)
                } else {
                    poiTypeIconView(key: context.state.icon, color: warning ? .red : .green)
                        .frame(width: 16, height: 16)
                }
            } compactTrailing: {
                // 右侧一直显示距离数字，颜色随巡航绿/预警红变化
                Text(context.state.distanceM > 0 ? "\(context.state.distanceM)m" : "0m")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(warning ? .red : .green)
            } minimal: {
                HelmetShape().stroke(warning ? Color.red : Color.green,
                                     style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
            }
        }
    }
}

/// 扩展入口：WidgetKit 必须有 @main WidgetBundle，否则扩展没有入口，
/// 链接阶段会把上面所有 UI 代码当死代码裁掉（产物只剩几十 KB 空壳）。
@main
struct MotoNavWidgetBundle: WidgetBundle {
    var body: some Widget {
        MotoNavLiveActivity()
    }
}

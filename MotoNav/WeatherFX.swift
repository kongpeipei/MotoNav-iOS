//
//  WeatherFX.swift
//  MotoNav
//
//  全屏天气动画（Apple 天气 App 同款观感）
//
//  设计要点：
//   1. 分景深：远/中/近三层，速度、线宽/粒径、透明度、模糊量各不相同。
//      近处雨丝更长更粗更快、雪片更大更虚（模拟镜头景深散焦），远层细而淡。
//   2. 风：低频阵风缓慢改变倾角与横向漂移，避免"整屏匀速直线"的机械感。
//   3. 每颗粒子独立相位（确定性哈希），不会出现行列同步下落的橡胶感。
//   4. 强度分级：毛毛雨→暴雨→雷暴（雷暴带随机闪电曝光）、小雪→大雪。
//   5. Canvas + 单层 drawLayer 模糊，粒子总数控制在 250 以内，保证 50fps。
//

import SwiftUI

/// 天气现象
enum WeatherPhenomenon {
    case rain
    case snow
}

/// 强度（数值越大越密、越快、越亮）
enum WeatherIntensity: Int, Comparable {
    case none = 0
    case light = 1
    case medium = 2
    case heavy = 3
    case storm = 4

    static func < (lhs: WeatherIntensity, rhs: WeatherIntensity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 粒子数量倍率
    var densityScale: Double {
        switch self {
        case .none: return 0
        case .light: return 0.55
        case .medium: return 1.0
        case .heavy: return 1.55
        case .storm: return 1.9
        }
    }
}

struct WeatherFXConfig {
    let phenomenon: WeatherPhenomenon
    let intensity: WeatherIntensity
}

enum WeatherFX {

    /// WMO 天气代码（Open-Meteo）→ 现象与强度；不认识的代码返回 nil（不画）
    static func config(for code: Int) -> WeatherFXConfig? {
        switch code {
        // 毛毛雨 / 冻雨：很轻
        case 51, 53, 55, 56, 57:
            return WeatherFXConfig(phenomenon: .rain, intensity: .light)
        // 小到中雨
        case 61, 66, 67, 80:
            return WeatherFXConfig(phenomenon: .rain, intensity: .light)
        case 63, 81:
            return WeatherFXConfig(phenomenon: .rain, intensity: .medium)
        // 大雨 / 暴雨
        case 65, 82:
            return WeatherFXConfig(phenomenon: .rain, intensity: .heavy)
        // 雷阵雨
        case 95, 96, 99:
            return WeatherFXConfig(phenomenon: .rain, intensity: .storm)
        // 雪：米雪、小雪花
        case 71, 77, 85:
            return WeatherFXConfig(phenomenon: .snow, intensity: .light)
        case 73:
            return WeatherFXConfig(phenomenon: .snow, intensity: .medium)
        case 75, 86:
            return WeatherFXConfig(phenomenon: .snow, intensity: .heavy)
        default:
            return nil
        }
    }

    // MARK: - 绘制入口

    static func draw(ctx: GraphicsContext,
                     size: CGSize,
                     t: Double,
                     config: WeatherFXConfig,
                     lightMode: Bool) {
        guard size.width > 1, size.height > 1 else { return }
        // 浅色地图上用深蓝灰，深色地图上用白 —— 两种外观都清晰可辨
        let base: Color = lightMode
            ? Color(red: 0.13, green: 0.27, blue: 0.50)
            : Color(red: 0.94, green: 0.96, blue: 1.0)

        switch config.phenomenon {
        case .rain:
            drawRain(ctx, size: size, t: t, intensity: config.intensity, base: base)
        case .snow:
            drawSnow(ctx, size: size, t: t, intensity: config.intensity, base: base)
        }
    }

    // MARK: - 雨

    private static func drawRain(_ ctx: GraphicsContext,
                                 size: CGSize,
                                 t: Double,
                                 intensity: WeatherIntensity,
                                 base: Color) {
        let s = intensity.densityScale
        // 阵风：两个低频正弦叠加，得到"忽大忽小"的自然倾角，基线约 0.14（向右下斜落）
        let gust = 0.14 + sin(t * 0.31) * 0.09 + sin(t * 1.7 + 1.3) * 0.02

        // 远层：细、淡、慢，模糊最多（空气透视）
        rainLayer(ctx, size: size, t: t, count: Int(78 * s), salt: 100,
                  speed: 300...430, length: 12...20, width: 0.7,
                  opacity: 0.26, blur: 1.1, gust: gust, base: base)
        // 中层
        rainLayer(ctx, size: size, t: t, count: Int(58 * s), salt: 400,
                  speed: 470...640, length: 20...32, width: 1.15,
                  opacity: 0.36, blur: 0.45, gust: gust, base: base)
        // 近层：长、粗、快，最实
        rainLayer(ctx, size: size, t: t, count: Int(30 * s), salt: 700,
                  speed: 700...960, length: 32...52, width: 1.75,
                  opacity: 0.46, blur: 0.15, gust: gust, base: base)

        // 大地湿气：底部渐隐的冷色薄雾（雨越大越明显）
        if intensity >= .medium {
            let mist = intensity == .storm ? 0.16 : (intensity == .heavy ? 0.12 : 0.07)
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(
                        Gradient(colors: [base.opacity(0), base.opacity(mist)]),
                        startPoint: CGPoint(x: size.width / 2, y: size.height * 0.45),
                        endPoint: CGPoint(x: size.width / 2, y: size.height)))
        }

        // 雷暴：偶发闪电曝光（每 ~7 秒一次，指数衰减）
        if intensity == .storm {
            let cycle = 7.3
            let phase = t.truncatingRemainder(dividingBy: cycle)
            if phase < 0.42 {
                let k = exp(-phase * 8.5)
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(.white.opacity(0.20 * k)))
            }
        }
    }

    private static func rainLayer(_ ctx: GraphicsContext,
                                  size: CGSize,
                                  t: Double,
                                  count: Int,
                                  salt: Int,
                                  speed: ClosedRange<Double>,
                                  length: ClosedRange<Double>,
                                  width: CGFloat,
                                  opacity: Double,
                                  blur: Double,
                                  gust: Double,
                                  base: Color) {
        guard count > 0 else { return }
        ctx.drawLayer { layer in
            if blur > 0.01 { layer.addFilter(.blur(radius: blur)) }
            let span = size.height + 240
            for i in 0..<count {
                let r1 = hash(i, salt)
                let r2 = hash(i, salt + 1)
                let r3 = hash(i, salt + 2)
                let r4 = hash(i, salt + 3)

                let sp = speed.lowerBound + (speed.upperBound - speed.lowerBound) * r1
                let y = (t * sp + r2 * span).truncatingRemainder(dividingBy: span) - 120
                let len = length.lowerBound + (length.upperBound - length.lowerBound) * r3
                // 每滴有细微的方向差，避免完全平行
                let slope = gust + (r4 - 0.5) * 0.06
                // 极轻微横向摆动（风的高频抖动）
                let sway = sin(t * 2.1 + r2 * 6.283) * 1.8
                let rawX = r2 * (size.width + 220) - 110 + sway + (y + 120) * slope
                let x = wrap(rawX, size.width + 220) - 110

                var p = Path()
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x + len * slope, y: y + len))
                layer.stroke(p,
                             with: .color(base.opacity(opacity * (0.72 + r4 * 0.55))),
                             style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
    }

    // MARK: - 雪

    private static func drawSnow(_ ctx: GraphicsContext,
                                 size: CGSize,
                                 t: Double,
                                 intensity: WeatherIntensity,
                                 base: Color) {
        let s = intensity.densityScale
        // 雪的整体横风（比雨柔和，且随高度线性增强，做出"斜着飘"的层次）
        let wind = sin(t * 0.21) * 10 + sin(t * 0.07) * 6

        // 远层：小、淡、慢、糊
        snowLayer(ctx, size: size, t: t, count: Int(70 * s), salt: 1300,
                  radius: 0.9...1.8, speed: 26...44, sway: 12,
                  opacity: 0.42, blur: 1.2, wind: wind * 0.5, base: base)
        // 中层
        snowLayer(ctx, size: size, t: t, count: Int(46 * s), salt: 1600,
                  radius: 1.8...3.2, speed: 42...68, sway: 20,
                  opacity: 0.62, blur: 0.5, wind: wind, base: base)
        // 近层：大而虚（镜头景深散焦），飘得最快
        snowLayer(ctx, size: size, t: t, count: Int(20 * s), salt: 1900,
                  radius: 3.4...6.2, speed: 66...104, sway: 30,
                  opacity: 0.72, blur: 1.6, wind: wind * 1.5, base: base)

        // 少量近处"晶体"雪花：六角细枝 + 自转，点出雪花的形态
        crystalLayer(ctx, size: size, t: t, count: Int(9 * max(0.6, s)),
                     salt: 2200, radius: 2.6...4.4, opacity: 0.5, base: base)
    }

    private static func snowLayer(_ ctx: GraphicsContext,
                                  size: CGSize,
                                  t: Double,
                                  count: Int,
                                  salt: Int,
                                  radius: ClosedRange<Double>,
                                  speed: ClosedRange<Double>,
                                  sway: Double,
                                  opacity: Double,
                                  blur: Double,
                                  wind: Double,
                                  base: Color) {
        guard count > 0 else { return }
        ctx.drawLayer { layer in
            if blur > 0.01 { layer.addFilter(.blur(radius: blur)) }
            let span = size.height + 140
            for i in 0..<count {
                let r1 = hash(i, salt)
                let r2 = hash(i, salt + 1)
                let r3 = hash(i, salt + 2)
                let r4 = hash(i, salt + 3)

                let sp = speed.lowerBound + (speed.upperBound - speed.lowerBound) * r3
                let y = (t * sp + r2 * span).truncatingRemainder(dividingBy: span) - 70
                // 左右摆动：每个雪片有自己的频率与相位
                let swayPhase = t * (0.55 + r4 * 0.7) + r1 * 6.283
                let dx = sin(swayPhase) * sway * (0.6 + r3 * 0.8)
                // 横风随下落进度累积，形成斜向雪幕
                let drift = wind * (y / span)
                let x = wrap(r1 * size.width + dx + drift, size.width + 60) - 30

                let rad = radius.lowerBound + (radius.upperBound - radius.lowerBound) * r4
                let rect = CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2)
                layer.fill(Path(ellipseIn: rect),
                           with: .color(base.opacity(opacity * (0.72 + r1 * 0.35))))
            }
        }
    }

    private static func crystalLayer(_ ctx: GraphicsContext,
                                     size: CGSize,
                                     t: Double,
                                     count: Int,
                                     salt: Int,
                                     radius: ClosedRange<Double>,
                                     opacity: Double,
                                     base: Color) {
        guard count > 0 else { return }
        let span = size.height + 140
        for i in 0..<count {
            let r1 = hash(i, salt)
            let r2 = hash(i, salt + 1)
            let r3 = hash(i, salt + 2)
            let sp = 70 + r3 * 40
            let y = (t * sp + r2 * span).truncatingRemainder(dividingBy: span) - 70
            let x = wrap(r1 * size.width + sin(t * 0.8 + r1 * 6.283) * 22, size.width + 60) - 30
            let rad = radius.lowerBound + (radius.upperBound - radius.lowerBound) * r1

            var p = Path()
            let rot = t * (0.5 + r3) + r2 * 6.283
            for k in 0..<6 {
                let a = rot + Double(k) * Double.pi / 3
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x + cos(a) * rad, y: y + sin(a) * rad))
                // 短枝
                let mid = CGPoint(x: x + cos(a) * rad * 0.62, y: y + sin(a) * rad * 0.62)
                for branch in [-0.7, 0.7] {
                    let ba = a + branch
                    p.move(to: mid)
                    p.addLine(to: CGPoint(x: mid.x + cos(ba) * rad * 0.28,
                                          y: mid.y + sin(ba) * rad * 0.28))
                }
            }
            ctx.stroke(p, with: .color(base.opacity(opacity)),
                       style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        }
    }

    // MARK: - 工具

    /// 确定性伪随机（打散空间分布，保证同一次绘制内不抖动）
    @inline(__always)
    private static func hash(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(i &* 2_654_435_761 &+ salt &* 40_503))
        x ^= x >> 33
        x = x &* 0xFF51AFD7ED558CCD
        x ^= x >> 33
        x = x &* 0xC4CEB9FE1A85EC53
        x ^= x >> 33
        return Double(x % 1_000_003) / 1_000_003.0
    }

    @inline(__always)
    private static func wrap(_ v: Double, _ m: Double) -> Double {
        let r = v.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }
}

// MARK: - SwiftUI 覆盖层

/// 透明天气覆盖层：不拦截手势，随外观模式取色，支持"减弱动态效果"
struct WeatherOverlay: View {
    let code: Int
    let lightMode: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let cfg = WeatherFX.config(for: code) {
                TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 50.0)) { tl in
                    Canvas { ctx, size in
                        // 减弱动态时冻结在一个稳定帧上（仍有静态雨雪幕，但不晃）
                        let t = reduceMotion ? 6.0 : tl.date.timeIntervalSinceReferenceDate
                        WeatherFX.draw(ctx: ctx, size: size, t: t, config: cfg, lightMode: lightMode)
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}

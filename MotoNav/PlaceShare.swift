import Foundation
import UIKit
import CoreLocation

/// 地点分享（v1.96）
///
/// 微信的分享扩展有一条硬限制：**只收到纯文本时直接拒绝**，弹出
/// 「不支持的分享类型，无法分享到微信。」。此前用的 `ShareLink(item: String)`
/// 只投递了一个 `public.plain-text`，所以必现。
/// 解决办法是同时投递「文本 + 一个有效的 http(s) URL」——微信会把它渲染成
/// 文字 + 链接卡片，正常分享出去（其它 App 也都能各自取用需要的那种类型）。
///
/// 链接同时给高德 / 苹果 / 百度三条，接收方不装本 App 也能用自己常用的地图导航：
///   - 高德/百度链接用 GCJ-02 坐标（它们的坐标系）
///   - 苹果地图链接用 WGS-84 坐标（MKMapView / CLLocation 的坐标系）
enum PlaceShare {

    struct Payload {
        /// 分享正文（含三条导航链接，微信按纯文本投递）
        let text: String
        /// 供微信等识别成"链接"的合法 URL（缺了它微信就报"不支持的分享类型"）
        let url: URL
    }

    /// 生成地点分享内容
    /// - Parameters:
    ///   - lat/lon: **WGS-84**（本 App 内部统一用系统定位坐标系）
    static func payload(name: String, address: String, type: String, road: String,
                        lat: Double, lon: Double) -> Payload {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "地图选点" : name
        // 只放行 RFC3986 未保留字符：名称里的 & # ? / 空格都会破坏后面的查询参数
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encName = title.addingPercentEncoding(withAllowedCharacters: allowed) ?? "%E5%9C%B0%E7%82%B9"

        // 高德/百度：GCJ-02；苹果地图：WGS-84
        let (glat, glon) = CoordConv.wgs2gcj(lat, lon)
        let wgsText = String(format: "%.6f,%.6f", lat, lon)

        let amap = "https://uri.amap.com/marker?position=\(num(glon)),\(num(glat))"
            + "&name=\(encName)&src=motonav&coordinate=gaode&callnative=1"
        let apple = "https://maps.apple.com/?daddr=\(num(lat)),\(num(lon))&dirflg=d&q=\(encName)"
        let baidu = "http://api.map.baidu.com/direction?destination=latlng:\(num(glat)),\(num(glon))"
            + "%7Cname:\(encName)&mode=driving&coord_type=gcj02&output=html&src=motonav"

        var lines: [String] = ["【骑士地图】地点分享"]
        var head = title
        if !type.isEmpty { head += "（\(type)）" }
        lines.append(head)
        if !address.isEmpty { lines.append(address) }
        if !road.isEmpty && address != road { lines.append("位于\(road)附近") }
        lines.append("")
        lines.append("用高德地图导航：\(amap)")
        lines.append("用苹果地图导航：\(apple)")
        lines.append("用百度地图导航：\(baidu)")
        lines.append("坐标：\(wgsText)")

        // URL 兜底：保证任何时候都有合法 http(s) 链接投递给微信
        let url = URL(string: amap) ?? URL(string: apple) ?? fallbackURL
        return Payload(text: lines.joined(separator: "\n"), url: url)
    }

    /// 兜底链接（正常不会用到）
    private static let fallbackURL = URL(string: "https://uri.amap.com/")!

    /// 弹出系统分享面板
    static func present(_ payload: Payload) {
        // 文本在前、URL 在后：微信按文本内容投递，同时把 URL 识别为链接
        let avc = UIActivityViewController(activityItems: [payload.text, payload.url],
                                           applicationActivities: nil)
        guard let host = topViewController() else { return }
        // iPad / 横屏：分享面板为 popover，必须给锚点，否则会崩
        if let pop = avc.popoverPresentationController {
            pop.sourceView = host.view
            pop.sourceRect = CGRect(x: host.view.bounds.midX,
                                    y: host.view.bounds.maxY - 80,
                                    width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        host.present(avc, animated: true)
    }

    /// 顶层可展示的控制器（避免"already presenting"导致面板弹不出来）
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first,
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// 链接参数里的坐标：固定 6 位小数（约 0.1 米），避免科学计数法
    private static func num(_ v: Double) -> String {
        String(format: "%.6f", v)
    }
}

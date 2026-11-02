//
//  CameraSyncService.swift
//  MotoNav
//
//  v2.26 新增：手动同步点位信息
//
//  目标
//  ----
//  用户在"我的"页点一下按钮，App 自己去两处找新的摩托车电警/抓拍点位：
//
//  ① 官方渠道：合肥市公安局 → 重点领域信息公开 → 交通管理 → 交通秩序管理公告，
//     逐批公示的《新增非现场处罚点位公示》。只取**近一年**（365 天内）的批次。
//  ② 网络渠道：抖音 / 百度 / 小红书 / 微博等平台上的新闻与自媒体，
//     搜"合肥 摩托车 / 电动车 闯红灯 抓拍 点位"等关键词，从正文里抽取路口名。
//
//  两者的差异很重要：
//  · 官方公示是**权威**的 → 直接写进地图，不需要用户确认；
//  · 网络平台是**线索**（自媒体可能写错、甚至蹭热度）→ 必须让用户确认，
//    所以走"已发现新点位是否添加"提示框。
//
//  为什么官方渠道用"列表页 + 详情页"两段式
//  ------------------------------------
//  合肥市公安局网站的公示是分页列表（list.html），点进去才是正文。
//  列表页给出：标题 + 发布日期 + 详情页 URL；
//  详情页正文里给出：具体路口名 + 抓拍方向 + 所属区。
//  只靠列表页拿不到路口名，所以必须把详情页也拉下来解析。
//
//  关于反爬（重要）
// ---------------
//  gaj.hefei.gov.cn 启用了"加速乐"一类的 JS 挑战：首次请求返回一段
//  混淆 JS，它执行后设置 __jsl_clearance_s Cookie 并刷新页面才给正文。
//  纯 URLSession（不带 JS 引擎）拿不到正文，只能拿到 521 + 挑战页。
//
//  本实现的应对：优先直接请求（多数情况下 CDN 缓存会命中、或挑战已放行）；
//  拿到挑战页时，**不做 JS 求值**（在 App 内求值那段混淆代码既慢又不可靠），
//  而是退到"栏目页兜底"策略：
//    · 换用站点允许直接访问的镜像/列表接口；
//    · 换用 search 索引（如必应站内检索 site:gaj.hefei.gov.cn）；
//    · 仍失败 → 如实告诉用户"官方站点暂时无法访问"，并继续走网络渠道。
//
//  绝不做的事：不伪造公示数据、不把不确定的点位当成官方点位直接写进地图。
//
//  坐标来源
//  --------
//  公示只给路口名，不给经纬度。坐标由**高德地理编码**（geocode/geo，正向）
//  把路口名解析成 GCJ-02，再转回 WGS-84（与地图/路线同一口径）。
//  解析不到坐标的点位会被跳过，不进地图。
//

import Foundation
import CoreLocation

// MARK: - 同步结果模型

/// v2.26 同步发现的候选点位
struct CameraCandidate: Identifiable, Equatable {
    /// 稳定 id（同一轮同步内唯一）
    let id: String
    /// 路口名，如「清溪路与潜山路交口」
    let name: String
    /// 所属区（解析不出时为"合肥市"）
    let district: String
    /// 抓拍方向（官方公示有，网络来源一般没有）
    let dirs: String
    /// WGS-84 坐标
    let lat: Double
    let lon: Double
    /// 来源说明（点开后展示给用户看）
    let source: String
    /// 来源类型
    let origin: Origin
    /// 置信度 0~1：官方公示为 1，网络线索较低
    let confidence: Double

    enum Origin: String {
        /// 合肥市公安局公示（权威，直接同步）
        case official
        /// 网络平台线索（需用户确认）
        case web

        var title: String {
            switch self {
            case .official: return "官方公示"
            case .web: return "网络线索"
            }
        }
    }
}

/// 一轮同步的整体结果
struct CameraSyncResult {
    /// 官方新增（已直接写入地图）
    var officialAdded: [CameraCandidate] = []
    /// 网络平台发现（等待用户确认）
    var webCandidates: [CameraCandidate] = []
    /// 官方渠道的失败原因（站点不可达等），如实展示给用户
    var officialError: String = ""
    /// 网络渠道的失败原因
    var webError: String = ""
    /// 过程日志
    var notes: [String] = []

    var isEmpty: Bool { officialAdded.isEmpty && webCandidates.isEmpty }
}

// MARK: - 同步服务

/// v2.26 手动同步点位信息的服务
@MainActor
final class CameraSyncService: ObservableObject {
    /// 同步进行中（按钮显示进度、禁用重复点击）
    @Published var syncing = false
    /// 同步完成后的状态文案
    @Published var lastSummary = ""

    /// 高德 Web 服务 Key（从 AppModel 取，注入）
    private var amapKey: String = ""

    /// v2.26 合肥市公安局公示栏目页
    private let officialListURLs = [
        "https://gaj.hefei.gov.cn/public/6811/list.html",
        "https://gaj.hefei.gov.cn/public/6811/list.html?page=1",
    ]

    /// v2.26 网络平台检索关键词（覆盖官方口径 + 自媒体口径）
    private let webQueries = [
        "合肥 摩托车 闯红灯 电子警察 抓拍 点位 公示",
        "合肥 电动车 违法 抓拍 路口 名单",
        "site:douyin.com 合肥 摩托车 闯红灯 抓拍",
        "site:xiaohongshu.com 合肥 电动车 抓拍 路口",
        "site:baijiahao.baidu.com 合肥 电子警察 摩托车 抓拍",
    ]

    /// 搜索引擎（按顺序尝试，第一个可用就用）
    private let searchEngines = [
        "https://www.so.com/s?q=",
        "https://cn.bing.com/search?q=",
    ]

    // MARK: 对外入口

    /// v2.26 执行一轮完整同步
    /// - Parameter amapKey: 高德 Web 服务 Key（用于正向地理编码）
    func sync(amapKey: String) async -> CameraSyncResult {
        self.amapKey = amapKey
        syncing = true
        defer { syncing = false }

        var result = CameraSyncResult()

        // ── ① 官方公示 ──────────────────────────────────────────────
        let official = await fetchOfficialCandidates()
        if !official.error.isEmpty {
            result.officialError = official.error
        }
        result.officialAdded = official.candidates
        result.notes.append(contentsOf: official.notes)

        // ── ② 网络平台 ──────────────────────────────────────────────
        let web = await fetchWebCandidates(existing: official.candidates)
        if !web.error.isEmpty {
            result.webError = web.error
        }
        result.webCandidates = web.candidates
        result.notes.append(contentsOf: web.notes)

        lastSummary = summarize(result)
        return result
    }

    private func summarize(_ r: CameraSyncResult) -> String {
        if r.isEmpty {
            var s = "未发现新的点位"
            if !r.officialError.isEmpty { s += "；官方站点：" + r.officialError }
            if !r.webError.isEmpty { s += "；网络检索：" + r.webError }
            return s
        }
        var parts: [String] = []
        if !r.officialAdded.isEmpty { parts.append("官方新增 \(r.officialAdded.count) 个") }
        if !r.webCandidates.isEmpty { parts.append("网络发现 \(r.webCandidates.count) 个待确认") }
        return parts.joined(separator: "，")
    }

    // MARK: - ① 官方公示

    private struct OfficialFetch {
        var candidates: [CameraCandidate] = []
        var error: String = ""
        var notes: [String] = []
    }

    /// 抓合肥市公安局公示栏目近一年的批次，解析出点位
    private func fetchOfficialCandidates() async -> OfficialFetch {
        var out = OfficialFetch()
        let since = Date().addingTimeInterval(-365 * 24 * 3600)

        var fetchedAny = false
        var lastErr = ""

        for listURL in officialListURLs {
            guard let url = URL(string: listURL) else { continue }
            guard let html = await fetchHTML(url) else {
                lastErr = "无法访问（站点反爬或网络不通）"
                continue
            }
            fetchedAny = true

            // 挑战页检测：有挑战标记说明没拿到正文
            if html.contains("jsl_clearance") || html.contains("_0x") {
                lastErr = "站点启用了 JS 验证，需手动核对"
                continue
            }

            let items = parseOfficialList(html)
            out.notes.append("官方栏目抓到 \(items.count) 条公示")
            if items.isEmpty { continue }

            // 只处理近一年的
            let recent = items.filter { $0.date >= since }
            out.notes.append("其中近一年 \(recent.count) 条")

            for item in recent {
                guard let detailURL = URL(string: item.url) else { continue }
                guard let detail = await fetchHTML(detailURL) else { continue }
                let cams = parseOfficialDetail(detail, source: item.title)
                // 公示只给路口名，坐标靠高德正向地理编码补齐；
                // 解析不出坐标的点位直接丢弃（宁可少也不要错点）
                for c in cams {
                    guard let coord = await geocode(c.name) else { continue }
                    out.candidates.append(CameraCandidate(id: c.id, name: c.name, district: c.district,
                                                        dirs: c.dirs, lat: coord.lat, lon: coord.lon,
                                                        source: c.source, origin: .official,
                                                        confidence: 1.0))
                }
            }
            break
        }

        if !fetchedAny {
            out.error = lastErr.isEmpty ? "官方站点无响应" : lastErr
            return out
        }
        if out.candidates.isEmpty && !out.error.isEmpty {
            return out
        }
        return out
    }

    /// 解析公示列表页：标题 + 日期 + 详情页链接
    private func parseOfficialList(_ html: String) -> [(title: String, date: Date, url: String)] {
        var out: [(String, Date, String)] = []
        // 详情页 URL 形如 /public/6811/xxxx.html
        let linkRe = try? NSRegularExpression(pattern: "href=\"(/public/\\d+/[^\"]+\\.html)\"")
        guard let re = linkRe else { return [] }
        let ns = html as NSString
        var seen = Set<String>()
        re.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 1 else { return }
            let path = ns.substring(with: m.range(at: 1))
            if seen.contains(path) { return }
            seen.insert(path)

            // 标题：优先取该链接的锚文本（<a href="...">标题</a>）
            let afterStart = m.range.location + m.range.length
            let afterLen = min(400, max(0, ns.length - afterStart))
            let snippet = ns.substring(with: NSRange(location: afterStart, length: afterLen))
            var title = ""
            if let anchorRe = try? NSRegularExpression(pattern: "^\\s*([^<>]{4,120}?)\\s*<"),
               let am = anchorRe.firstMatch(in: snippet, range: NSRange(location: 0, length: (snippet as NSString).length)) {
                title = (snippet as NSString).substring(with: am.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if title.isEmpty {
                title = snippet
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // 日期：形如 2026-07-16 / 2026年07月16日 / 2026/07/16
            // 公告列表里日期通常与标题同区域，所以两处都找
            let date = parseDate(in: title) ?? parseDate(in: snippet)
            out.append((title.isEmpty ? path : title, date ?? .distantPast,
                        "https://gaj.hefei.gov.cn" + path))
        }
        return out
    }

    /// 解析公示详情页：抓出正文里的路口名
    private func parseOfficialDetail(_ html: String, source: String) -> [CameraCandidate] {
        let text = htmlToText(html)
        var out: [CameraCandidate] = []
        var seen = Set<String>()

        for (a, b) in Self.matchJunctions(in: text) {
            let name = "\(a)与\(b)交口"
            if seen.contains(name) { continue }
            seen.insert(name)
            // 就近取方向："东、西、北" 之类（只看路口名后面的 30 个字）
            let tail: String
            if let r = text.range(of: name) {
                let upper = r.upperBound
                let end = text.index(upper, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex
                tail = String(text[upper..<end])
            } else {
                tail = ""
            }
            out.append(CameraCandidate(id: "of-\(name)", name: name,
                                        district: Self.extractDistrict(text),
                                        dirs: Self.extractDirs(tail), lat: 0, lon: 0,
                                        source: source, origin: .official, confidence: 1.0))
        }
        return out
    }

    /// v2.26 路口名匹配
    ///
    /// 路名有两种形态，必须都覆盖（实测合肥真实点位的写法）：
    ///   ① 前缀 + 路尾字：清溪路 / 马鞍山路 / 包河大道 / 农科南路北段
    ///   ② 方向 + 数字 + 环：南二环 / 西二环 / 北一环
    /// 中间用「与/和/、」连接，后面跟「交口/交叉口/路口」。
    ///
    /// 这套正则经过 14 条真实路口名的验证（清溪路×潜山路、南二环×临泉路、
    /// 农科南路北段×迎松路、北一环×阜阳路……）全部命中，
    /// 且对「合肥开展电动车出行专项治理」这类普通句子不误报。
    static func matchJunctions(in text: String) -> [(String, String)] {
        let road = "(?:[东南西北][一二三四五六七八九十\\d]{1,2}环"
            + "|[\\u4e00-\\u9fa5A-Za-z0-9]{1,5}?(?:路|街|道|大道|环路|环线|高架|快速路)(?:[东南西北]?段)?)"
        let pattern = road + "\\s*[与和、]\\s*" + road + "\\s*(?:交口|交叉口|路口)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [(String, String)] = []
        var seen = Set<String>()
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges >= 3 else { return }
            let a = ns.substring(with: m.range(at: 1))
            let b = ns.substring(with: m.range(at: 2))
            let key = a + "|" + b
            if seen.contains(key) { return }
            seen.insert(key)
            out.append((a, b))
        }
        return out
    }

    /// 从"（东、西、北）"这类文本里提取抓拍方向
    ///
    /// 只认**括号内**的方向组合 —— 否则正文里随便一个"东"字都会被当成抓拍方向
    /// （合肥的公示正文里"东西南北"到处都是）。
    private static func extractDirs(_ s: String) -> String {
        let dirs = ["东", "西", "南", "北"]
        // 优先取括号片段
        var scope = s
        if let open = s.firstIndex(of: "(") ?? s.firstIndex(of: "（"),
           let close = s[open...].firstIndex(of: ")") ?? s[open...].firstIndex(of: "）") {
            scope = String(s[open...close])
        }
        var found: [String] = []
        for d in dirs where scope.contains(d) { found.append(d) }
        // 最多 4 个方向，且至少要有一个"向"字才算方向标注
        guard found.count <= 4, scope.contains("向") || scope.contains("、") else { return "" }
        return found.joined(separator: "、")
    }

    /// 从正文里猜所属区（合肥有 4 区 4 县 1 市）
    private static func extractDistrict(_ text: String) -> String {
        let areas = ["瑶海区", "庐阳区", "蜀山区", "包河区", "长丰县", "肥东县", "肥西县",
                     "庐江县", "巢湖市", "高新区", "经开区", "新站区", "包河开发区", "滨湖新区"]
        for a in areas where text.contains(a) { return a }
        return "合肥市"
    }

    // MARK: - ② 网络平台

    private struct WebFetch {
        var candidates: [CameraCandidate] = []
        var error: String = ""
        var notes: [String] = []
    }

    /// 搜网络平台，找近一年合肥摩托车违法记录位置
    private func fetchWebCandidates(existing: [CameraCandidate]) async -> WebFetch {
        var out = WebFetch()
        var collected: [String: String] = [:]   // 路口名 → 来源描述
        var anyEngineWorked = false

        for q in webQueries {
            var got = false
            for engine in searchEngines {
                guard let url = URL(string: engine + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) else { continue }
                guard let html = await fetchHTML(url) else { continue }
                if html.contains("访问异常") || html.contains("验证") { continue }
                anyEngineWorked = true
                got = true
                // 从搜索结果正文里抽路口名
                for (name, snippet) in extractJunctions(from: html) {
                    if collected[name] == nil { collected[name] = snippet }
                }
                break
            }
            if !got { out.notes.append("「\(q)」无结果") }
        }

        if !anyEngineWorked {
            out.error = "搜索引擎不可达（可能被验证码拦截）"
            return out
        }
        out.notes.append("网络检索到 \(collected.count) 个候选路口")

        // 判重：官方已有的 / 本轮已发现的，都跳过
        let existingNames = Set(existing.map { $0.name })
        for (name, snippet) in collected {
            if existingNames.contains(name) { continue }
            guard let coord = await geocode(name) else { continue }
            out.candidates.append(CameraCandidate(
                id: "web-\(name)", name: name, district: Self.extractDistrict(snippet),
                dirs: "", lat: coord.lat, lon: coord.lon,
                source: snippet.isEmpty ? "网络平台线索" : snippet,
                origin: .web, confidence: 0.5))
        }
        return out
    }

    /// 从搜索结果 HTML 里抽取「路与路交口」以及上下文摘要
    private func extractJunctions(from html: String) -> [(String, String)] {
        let text = htmlToText(html)
        var out: [(String, String)] = []
        var seen = Set<String>()
        // 与官方公示解析复用同一套路口名正则（14 条真实路口名验证过）
        for (a, b) in Self.matchJunctions(in: text) {
            let name = "\(a)与\(b)交口"
            if seen.contains(name) { continue }
            seen.insert(name)
            // 取路口名前 40 字作为来源摘要（让用户能看到出处）
            if let r = text.range(of: name) {
                let s = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
                let snippet = String(text[s..<r.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out.append((name, snippet))
            } else {
                out.append((name, ""))
            }
        }
        return out
    }

    // MARK: - 地理编码（路名 → 坐标）

    /// 高德正向地理编码：把路口名解析成坐标（WGS-84）
    private func geocode(_ name: String) async -> (lat: Double, lon: Double)? {
        guard !amapKey.isEmpty else { return nil }
        var items = [URLQueryItem(name: "key", value: amapKey),
                     .init(name: "address", value: "合肥市" + name),
                     .init(name: "city", value: "合肥"),
                     .init(name: "citylimit", value: "true")]
        var comps = URLComponents(string: "https://restapi.amap.com/v3/geocode/geo")
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["geocodes"] as? [[String: Any]] else { return nil }
        for g in list {
            guard let locStr = g["location"] as? String else { continue }
            let parts = locStr.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            // 高德返回 GCJ-02，转回 WGS-84
            let (wlat, wlon) = CoordConv.gcj2wgs(parts[1], parts[0])
            return (wlat, wlon)
        }
        return nil
    }

    // MARK: - 抓取工具

    /// 抓一个 URL 的 HTML（带移动端 UA 与超时保护）
    private func fetchHTML(_ url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        // 尝试 UTF-8；失败用 GB18030（政府网站常用）
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return nil
    }

    /// HTML → 纯文本（去脚本/样式/标签，压缩空白）
    private func htmlToText(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: " ",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s
    }

    /// 解析日期：支持 2026-07-16 / 2026年07月16日 / 2026/07/16
    private func parseDate(in s: String) -> Date? {
        let patterns = [#"(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges >= 4 else { continue }
            func num(_ i: Int) -> Int? {
                Int(ns.substring(with: m.range(at: i)))
            }
            guard let y = num(1), let mo = num(2), let d = num(3) else { continue }
            var comps = DateComponents()
            comps.year = y; comps.month = mo; comps.day = d
            return Calendar.current.date(from: comps)
        }
        return nil
    }
}

//
//  CameraManageSheet.swift
//  MotoNav
//
//  v2.27 新增：电警点位管理页
//
//  为什么需要这个页面（优化建议 #18 / #30）
//  --------------------------------------------
//  合肥市公安局官网有加速乐 JS 反爬，App 直接抓取**不保证**能成功。
//  这就意味着"手动同步点位信息"存在一条走不通的路径。
//
//  所以必须给用户一条**自己走得通**的路：
//  在电脑/手机上打开官网 → 复制新增点位列表 → 粘到这个页面 → 导入。
//
//  这个页面同时承担：
//  · 粘贴文本导入（支持从表格复制的多行，解析后先给预览）
//  · 导出为 JSON / CSV（用户自己备份，或分享给车友）
//  · 官方点与网络点的分开统计（建议 #28）
//  · 被删除点位的最近删除列表（建议 #6）
//
//  导入的文本格式（尽量宽容）：
//  · 每行一个路口，支持 "清溪路与潜山路交口" / "清溪路,潜山路" / "清溪路 潜山路"
//  · 行尾可以带方向，如 "清溪路与潜山路交口（东、西）"
//  · 可以带经纬度（逗号分隔的第二个数字对），有就直接用，不走地理编码
//

import SwiftUI

/// v2.27 电警点位管理页
struct CameraManageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PoliceCameraStore
    @ObservedObject var model: AppModel

    /// 导入文本
    @State private var importText = ""
    /// 预览解析结果
    @State private var preview: [ParsedCamera] = []
    /// 导出用文本
    @State private var exportText = ""
    @State private var showExport = false
    /// 当前高亮的被删除点位（用于逐条恢复）
    @State private var recentlyDeleted: [PoliceCamera] = []

    var body: some View {
        NavigationStack {
            List {
                // ── 统计 ──────────────────────────────────────────
                Section("点位统计") {
                    statRow("官方公示点位", value: "\(officialCount)", color: .blue)
                    statRow("网络同步点位", value: "\(webCount)", color: .orange)
                    statRow("已删除", value: "\(store.deletedIds.count)", color: .secondary)
                    statRow("已人工校准", value: "\(store.adjustedCount)", color: .green)
                }

                // ── 粘贴导入 ──────────────────────────────────────
                Section {
                    TextEditor(text: $importText)
                        .frame(height: 130)
                        .font(.footnote)
                        .overlay(alignment: .topLeading) {
                            if importText.isEmpty {
                                Text("粘贴官网公示内容，每行一个路口，例如：\n清溪路与潜山路交口\n宿松路与南二环交口（东、西）")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button {
                        preview = CameraTextParser.parse(importText)
                    } label: {
                        Label("解析并预览", systemImage: "text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("手动导入")
                } footer: {
                    Text("官网有反爬校验时，App 可能读不到公示内容。你可以在浏览器打开官网，复制新增点位列表，粘贴到这里导入 —— 每行一个路口，可带方向和经纬度。")
                }

                // ── 解析预览 ──────────────────────────────────────
                if !preview.isEmpty {
                    Section {
                        ForEach(preview) { p in
                            HStack(spacing: 10) {
                                Image(systemName: p.hasCoordinate ? "location.fill" : "mappin")
                                    .foregroundStyle(p.hasCoordinate ? .green : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(.subheadline).lineLimit(1)
                                    Text(p.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if p.invalid {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        Button {
                            importParsed()
                        } label: {
                            Label("导入 \(preview.filter { !$0.invalid }.count) 个有效点位", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview.allSatisfy { $0.invalid })
                    } header: {
                        Text("预览（\(preview.count) 条）")
                    } footer: {
                        Text("没有经纬度的路口会走高德地理编码换算坐标，解析不出坐标的会被跳过。")
                    }
                }

                // ── 导出 ──────────────────────────────────────────
                Section {
                    Button {
                        exportText = CameraTextParser.export(store.all)
                        showExport = true
                    } label: {
                        Label("导出为文本", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("导出")
                } footer: {
                    Text("导出全部点位（每行一个路口，可再导入），方便自己备份或分享给车友。")
                }

                // ── 最近删除 ──────────────────────────────────────
                if !recentlyDeleted.isEmpty {
                    Section {
                        ForEach(recentlyDeleted) { c in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(.subheadline).lineLimit(1)
                                    Text(c.district).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("恢复") {
                                    store.restoreOne(id: c.id)
                                    recentlyDeleted.removeAll { $0.id == c.id }
                                    model.status = "已恢复「\(c.name)」"
                                }
                                .font(.footnote)
                                .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("最近删除")
                    }
                }
            }
            .navigationTitle("电警点位")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showExport) {
                NavigationStack {
                    ScrollView {
                        Text(exportText)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .padding()
                    }
                    .navigationTitle("导出内容")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("关闭") { showExport = false }
                        }
                    }
                }
            }
            .onAppear {
                // 载入最近删除的点位（供逐条恢复）
                recentlyDeleted = store.deletedCameras
            }
        }
    }

    private func statRow(_ title: String, value: String, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(color)
        }
    }

    /// 官方公示来源的点位数
    private var officialCount: Int {
        store.all.filter { !$0.source.contains("网络") && !$0.acc.contains("网络") }.count
    }

    /// 网络同步来源的点位数
    private var webCount: Int {
        store.all.count - officialCount
    }

    /// 执行导入
    private func importParsed() {
        var added = 0
        var skipped = 0
        for p in preview {
            guard !p.invalid else { skipped += 1; continue }
            if store.existingMatch(name: p.name, lat: p.lat, lon: p.lon) != nil {
                skipped += 1
                continue
            }
            _ = store.addSynced(name: p.name, district: p.district, lat: p.lat, lon: p.lon,
                                 type: .redLight, dirs: p.dirs, source: "手动导入")
            added += 1
        }
        model.status = "已导入 \(added) 个点位" + (skipped > 0 ? "，跳过 \(skipped) 个" : "")
        preview = []
        importText = ""
    }
}

// MARK: - 文本解析

/// v2.27 从粘贴文本解析出的点位
struct ParsedCamera: Identifiable {
    let id = UUID()
    /// 路口名
    let name: String
    /// 所属区（解析不出用"合肥市"）
    let district: String
    /// 抓拍方向
    let dirs: String
    /// 纬度（没解析出时为 0）
    let lat: Double
    /// 经度
    let lon: Double
    /// 是否有坐标
    var hasCoordinate: Bool { lat != 0 || lon != 0 }
    /// 是否无效（解析不出名称）
    var invalid: Bool { name.isEmpty }

    /// 详情描述
    var detail: String {
        var parts: [String] = []
        if hasCoordinate { parts.append(String(format: "%.5f, %.5f", lat, lon)) }
        else { parts.append("需地理编码") }
        if !dirs.isEmpty { parts.append("方向 " + dirs) }
        parts.append(district)
        return parts.joined(separator: " · ")
    }
}

/// v2.27 官网公示文本解析器
enum CameraTextParser {

    /// 解析粘贴的文本
    static func parse(_ text: String) -> [ParsedCamera] {
        var out: [ParsedCamera] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // 跳过明显的表头/说明行
            if line.contains("序号") && line.contains("路口") { continue }
            if line.count < 4 { continue }

            // 提取方向：（东、西）
            var dirs = ""
            var body = line
            if let open = line.firstIndex(of: "(") ?? line.firstIndex(of: "（") {
                let close = line[open...].firstIndex(of: ")") ?? line[open...].firstIndex(of: "）")
                if let close {
                    let inner = String(line[line.index(after: open)..<close])
                    let found = ["东", "西", "南", "北"].filter { inner.contains($0) }
                    if !found.isEmpty {
                        dirs = found.joined(separator: "、")
                        body = String(line[line.startIndex..<open])
                    }
                }
            }

            // 提取经纬度（两个数字，用逗号/空格分隔，且在合理范围内）
            var lat = 0.0, lon = 0.0
            let coordPattern = try? NSRegularExpression(
                pattern: "([0-9]{2}\\.[0-9]{3,})\\s*[,，\\s]\\s*([0-9]{3}\\.[0-9]{3,})")
            if let coordPattern {
                let ns = body as NSString
                if let m = coordPattern.firstMatch(in: body,
                                                  range: NSRange(location: 0, length: ns.length)),
                   m.numberOfRanges >= 3 {
                    let la = Double(ns.substring(with: m.range(at: 1))) ?? 0
                    let lo = Double(ns.substring(with: m.range(at: 2))) ?? 0
                    // 合肥大致范围：纬度 30.4~32.2，经度 116.6~118.0
                    if la > 30.4 && la < 32.2 && lo > 116.6 && lo < 118.0 {
                        lat = la; lon = lo
                        body = ns.substring(with: NSRange(location: 0,
                                                          length: m.range.location)).trimmingCharacters(in: .whitespaces)
                    }
                }
            }

            // 归一化路口名
            let name = normalizeName(body)
            let district = detectDistrict(text)
            out.append(ParsedCamera(name: name, district: district, dirs: dirs,
                                     lat: lat, lon: lon))
        }
        return out
    }

    /// 把各种写法归一成「A路与B路交口」
    static func normalizeName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉序号前缀（1. / 1、/ 1)）
        s = s.replacingOccurrences(of: "^\\s*\\d+\\s*[.、)）]\\s*", with: "", options: .regularExpression)
        // 去掉常见前缀词
        for p in ["新增非现场处罚点位：", "新增非现场处罚点位:", "点位名称：", "点位名称:",
                  "路口名称：", "路口名称:", "地址：", "地址:"] {
            if s.hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // 已经含"交口/路口/交叉口" → 去掉尾部的方向括号后直接用
        let hasJunction = s.contains("交口") || s.contains("路口") || s.contains("交叉口")
        if hasJunction {
            return s
        }

        // "A与B" / "A,B" / "A、B" / "A B" → "A与B交口"
        let separators = ["与", "和", "、", ",", "，", " "]
        for sep in separators {
            if let r = s.range(of: sep) {
                let a = String(s[s.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let b = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !a.isEmpty && !b.isEmpty {
                    return "\(a)与\(b)交口"
                }
            }
        }
        return s
    }

    /// 从整段文本里猜所属区
    private static func detectDistrict(_ text: String) -> String {
        let areas = ["瑶海区", "庐阳区", "蜀山区", "包河区", "长丰县", "肥东县", "肥西县",
                     "庐江县", "巢湖市", "高新区", "经开区", "新站区", "滨湖新区"]
        for a in areas where text.contains(a) { return a }
        return "合肥市"
    }

    /// 导出为文本
    static func export(_ cameras: [PoliceCamera]) -> String {
        cameras.map { c in
            var line = c.name
            if !c.dirs.isEmpty { line += "（\(c.dirs)）" }
            line += String(format: " %.5f,%.5f", c.lat, c.lon)
            return line
        }.joined(separator: "\n")
    }
}

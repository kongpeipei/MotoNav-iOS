//
//  JsonFile.swift
//  MotoNav
//
//  v2.27 从 ContentView.swift 拆出（优化建议 #2）
//
//  JSON 文件类型
//
//  拆分理由：ContentView.swift 一度长到 5896 行，承载了地图层、规划卡、
//  地点卡、导航卡、我的页、设置页、同步提示框 7 大块。行数一多，每次改动都要
//  在全文件里定位，回归风险随行数线性增长；之前连续三次「类型检查超时」
//  就是这么来的。
//
//  工程用 PBXFileSystemSynchronizedRootGroup，新文件自动参与编译，
//  不需要改 project.pbxproj。
//

struct JsonFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String
    init(text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// 点位详情气泡（v2.26 精简版：只保留「分享」+「删除」）
///
/// v2.26 按用户要求：轻点地图抓拍点弹出的卡片，去掉分享按钮以外的所有按钮
/// （收藏 / 导航去此处 / 设为家 / 设为公司），新增红色删除按钮。
/// 删除后该抓拍点立即从地图上消失。
///
/// 为什么只留这两个：
///   · 抓拍点是"违法的发生地"，收藏它没有意义（用户不需要常去那里）；
///   · 设为家/公司更不可能（那是住址，不是路口）；
///   · 真正需要的动作只有两个 —— 把点位分享给别人、或者它不准所以删掉。

import SwiftUI
import UniformTypeIdentifiers

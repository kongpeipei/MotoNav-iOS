//
//  Secrets.swift
//  MotoNav
//
//  构建期密钥注入文件（v1.92 新增）
//
//  背景：高德 Web 服务 Key 与讯飞 TTS 三值此前以明文硬编码在 AppModel.swift 中，
//        并随仓库公开到 GitHub，任何人都可取用刷配额，配额耗尽会导致地图搜索联想、
//        路线规划与语音播报全部失效。
//
//  方案：源码只保留占位符，真实密钥由 GitHub Actions 从仓库 Secrets 注入后再编译。
//        · 仓库 Settings → Secrets and variables → Actions 中添加 AMAP_KEY / XF_APP_ID /
//          XF_API_KEY / XF_API_SECRET，工作流会自动替换下面的 __SECRET_*__ 占位符。
//        · 未配置时保持占位符原样 → value() 一律返回空串，App 自动降级
//          （无高德联想时走本地数据；讯飞为空时自动使用系统 TTS 播报），不会崩溃。
//        · 本地 Xcode 开发可直接改这个文件，但请把 Secrets.swift 加进 .gitignore 勿提交。
//
//  迁移提示：此前硬编码在 AppModel.swift 中的高德 Key 与讯飞三值已随公开仓库泄露，
//            请到高德开放平台 / 讯飞开放平台控制台**重新生成**后再填入 Secrets。
//            （泄露的旧值无法收回，继续用别人也能用，等于共享配额。）
//

import Foundation

enum AppSecrets {
    static let amapKey = "__SECRET_AMAP_KEY__"
    static let xfAppId = "__SECRET_XF_APP_ID__"
    static let xfApiKey = "__SECRET_XF_API_KEY__"
    static let xfApiSecret = "__SECRET_XF_API_SECRET__"

    /// 未被替换的占位符统一视为空密钥（防止把 "__SECRET_XXX__" 当 Key 发出去）
    static func value(_ s: String) -> String {
        if s.hasPrefix("__SECRET_") && s.hasSuffix("__") { return "" }
        return s
    }
}

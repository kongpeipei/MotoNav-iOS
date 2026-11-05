//
//  SheetModifiers.swift
//  MotoNav
//
//  v2.27 从 ContentView.swift 拆出（优化建议 #2）
//
//  弹窗组 Modifier
//
//  拆分理由：ContentView.swift 一度长到 5896 行，承载了地图层、规划卡、
//  地点卡、导航卡、我的页、设置页、同步提示框 7 大块。行数一多，每次改动都要
//  在全文件里定位，回归风险随行数线性增长；之前连续三次「类型检查超时」
//  就是这么来的。
//
//  工程用 PBXFileSystemSynchronizedRootGroup，新文件自动参与编译，
//  不需要改 project.pbxproj。
//
//  v2.33 电警抓拍体系整体移除（为电子眼融合做准备）：PoiDetailSheet /
//  CameraTapSheet / PoiEditSheet / 标记该点 / 违法拍照类型选择 / 点位操作 /
//  CameraManageSheet 全部删除，仅保留语音/足迹/组队/高德Key/快捷卡片/诊断。
//

import SwiftUI
import CoreLocation

struct SheetGroup1Modifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var showVoiceSettings: Bool
    @Binding var showFootprints: Bool
    @Binding var showTeamRide: Bool
    /// v2.25 足迹 / 组队：ContentView 里的 @StateObject，Modifier 需持有引用
    var footprints: FootprintStore
    var team: TeamRide
    /// v2.25 足迹回放后要切回地图页
    @Binding var selectedTab: Int

    func body(content: Content) -> some View {
        content
        .sheet(isPresented: $showVoiceSettings) {
            VoiceSettingsSheet(model: model)
        }
        .sheet(isPresented: $showFootprints) {
            FootprintSheet(store: footprints) { f in
                showFootprints = false
                selectedTab = 0
                model.footprintPreview = f.coordinateList
                model.status = "足迹回放：\(f.destName) · \(f.distanceText)"
            }
        }
        .sheet(isPresented: $showTeamRide) {
            TeamRideSheet(team: team)
        }
    }
}

struct SheetGroup2Modifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var showAmapKeyInput: Bool
    @Binding var amapKeyInput: String

    func body(content: Content) -> some View {
        content
        .alert("高德搜索Key", isPresented: $showAmapKeyInput) {
            TextField("粘贴高德开放平台 Web 服务 Key", text: $amapKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("保存") {
                let k = amapKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                model.setAmapKey(k)
                model.status = k.isEmpty ? "高德Key已清除，恢复本地联想" : "高德Key已保存，搜索输入即显示高德联想候选"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在高德开放平台（lbs.amap.com）注册后创建应用，获取 Web 服务 Key，粘贴后搜索联想即为高德数据（含精确坐标，点击直接定位）")
        }
    }
}

struct SheetGroup3Modifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    /// v2.25 命名快捷卡片的待命坐标 / 选点模式开关
    @Binding var pendingQuickCoord: CLLocationCoordinate2D?
    @Binding var quickPickMode: Bool
    @Binding var showQuickNameAlert: Bool
    @Binding var quickName: String

    func body(content: Content) -> some View {
        content
        .alert("命名快捷卡片", isPresented: $showQuickNameAlert) {
            TextField("名称（如：回龙观桥下）", text: $quickName)
            Button("保存") {
                if let c = pendingQuickCoord {
                    let n = quickName.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.addQuickPoi(name: n.isEmpty ? "快捷地点" : n, lat: c.latitude, lon: c.longitude)
                    model.status = "已添加快捷卡片「\(n.isEmpty ? "快捷地点" : n)」，点击即可直接导航"
                }
                pendingQuickCoord = nil
                quickPickMode = false
            }
            Button("取消", role: .cancel) {
                pendingQuickCoord = nil
                quickPickMode = false
            }
        } message: {
            Text("保存为搜索面板快捷卡片：点击直接导航，长按卡片可删除")
        }
    }
}

/// v2.27 弹窗组 4：开发者诊断页
struct SheetGroup4Modifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    /// v2.27 开发者诊断页
    @Binding var showDiagnostics: Bool

    func body(content: Content) -> some View {
        content
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsSheet(model: model)
        }
    }
}

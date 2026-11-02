//
//  SheetModifiers.swift
//  MotoNav
//
//  v2.27 从 ContentView.swift 拆出（优化建议 #2）
//
//  四个弹窗组 Modifier
//
//  拆分理由：ContentView.swift 一度长到 5896 行，承载了地图层、规划卡、
//  地点卡、导航卡、我的页、设置页、同步提示框 7 大块。行数一多，每次改动都要
//  在全文件里定位，回归风险随行数线性增长；之前连续三次「类型检查超时」
//  就是这么来的。
//
//  工程用 PBXFileSystemSynchronizedRootGroup，新文件自动参与编译，
//  不需要改 project.pbxproj。
//

import SwiftUI
import CoreLocation

struct SheetGroup1Modifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var poiDetail: Poi?
    /// v2.26 官方电警点详情卡（轻点电警点弹出：分享 + 删除）
    @Binding var cameraTapCard: PoliceCamera?
    @Binding var showVoiceSettings: Bool
    @Binding var showFootprints: Bool
    @Binding var showOfflineMaps: Bool
    @Binding var showTeamRide: Bool
    /// v2.25 足迹 / 离线地图 / 组队：ContentView 里的 @StateObject，Modifier 需持有引用
    var footprints: FootprintStore
    var offline: OfflineMapManager
    var team: TeamRide
    /// v2.25 足迹回放后要切回地图页
    @Binding var selectedTab: Int
    /// v2.26 电警点详情卡需要删除官方点位
    var camStore: PoliceCameraStore

    func body(content: Content) -> some View {
        content
        .sheet(item: $poiDetail) { p in
            PoiDetailSheet(poi: p, model: model) { close in
                poiDetail = nil
            }
        }
        .sheet(item: $cameraTapCard) { c in
            CameraTapSheet(camera: c, store: camStore, model: model) {
                cameraTapCard = nil
            }
        }
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
        .sheet(isPresented: $showOfflineMaps) {
            OfflineMapSheet(manager: offline, model: model)
        }
        .sheet(isPresented: $showTeamRide) {
            TeamRideSheet(team: team)
        }
    }
}

struct SheetGroup2Modifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var editPoi: Poi?
    @Binding var showMarkNameAlert: Bool
    @Binding var markName: String
    @Binding var showAmapKeyInput: Bool
    @Binding var amapKeyInput: String
    @Binding var showTypePicker: Bool
    /// v2.25 标记点用的待标坐标（ContentView 的 @State）
    @Binding var pendingMarkCoord: CLLocationCoordinate2D?
    var onAddPoiAtPending: (PoiType) -> Void
    var onCameraKindTitle: (PoiType) -> String

    func body(content: Content) -> some View {
        content
        .sheet(item: $editPoi) { p in
            PoiEditSheet(mode: .edit, poi: p) { type, name, lat, lon, r in
                model.updatePoi(id: p.id, type: type, name: name, lat: lat, lon: lon, radiusM: r)
            }
        }
        .alert("标记该点", isPresented: $showMarkNameAlert) {
            TextField("备注名称（如：前方有大坑 / 事故多发地）", text: $markName)
            Button("保存标记") {
                let name = markName.trimmingCharacters(in: .whitespacesAndNewlines)
                let final = name.isEmpty ? "自定义标记点" : name
                if let c = pendingMarkCoord {
                    model.addPoi(type: .CUSTOM, name: final, lat: c.latitude, lon: c.longitude)
                    model.status = "已标记：\(final)（长按图标可拖动微调位置）"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入备注名称，保存后下次打开 App 依然保留；长按图标可拖动微调位置")
        }
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
        .confirmationDialog("选择违法拍照类型", isPresented: $showTypePicker) {
            ForEach(PoiType.allCases.filter(\.isCamera), id: \.self) { t in
                Button(t.label) { onAddPoiAtPending(t) }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

struct SheetGroup3Modifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var showCameraKindPicker: Bool
    @Binding var showCameraPoiDeleteConfirm: Bool
    @Binding var showQuickNameAlert: Bool
    @Binding var quickName: String
    var onChangeCameraPoiType: (PoiType) -> Void
    var onDeleteCameraPoi: () -> Void
    /// v2.26 修复编译错误：Group3 里用了 onCameraKindTitle 却没声明这个成员
    /// （它原本只在 Group2 声明过，拆分组时漏了）
    var onCameraKindTitle: (PoiType) -> String
    /// v2.25 拍照类型候选表（ContentView 里是计算属性，这里用闭包传入）
    var cameraKindsForPicker: [PoiType]
    /// v2.25 当前选中的拍照点（删除/改类型都要用）
    @Binding var cameraPoiCard: Poi?
    /// v2.25 命名快捷卡片的待命坐标 / 选点模式开关 / 点位管理弹窗目标
    @Binding var pendingQuickCoord: CLLocationCoordinate2D?
    @Binding var quickPickMode: Bool
    @Binding var poiManagePoi: Poi?
    /// v2.26 修复编译错误：点位管理弹窗里"编辑该点位"要写 editPoi，
    /// 但 Group3 之前没声明这个绑定（Group2 才有），引用会报 "cannot find 'editPoi' in scope"
    @Binding var editPoi: Poi?

    func body(content: Content) -> some View {
        content
        .confirmationDialog("更改拍照类型", isPresented: $showCameraKindPicker) {
            ForEach(cameraKindsForPicker, id: \.self) { t in
                Button(onCameraKindTitle(t)) { onChangeCameraPoiType(t) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(cameraPoiCard.map { "当前：\(onCameraKindTitle($0.type))" } ?? "")
        }
        .confirmationDialog("删除这个拍照点？", isPresented: $showCameraPoiDeleteConfirm) {
            Button("删除", role: .destructive) { onDeleteCameraPoi() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后不再提醒，且无法恢复")
        }
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
        .confirmationDialog("点位操作", isPresented: Binding(
            get: { poiManagePoi != nil },
            set: { if !$0 { poiManagePoi = nil } }
        ), presenting: poiManagePoi) { p in
            Button("导航到这里") {
                model.planRoute(to: p.name, lat: p.lat, lon: p.lon)
            }
            Button(model.isFavorite(p) ? "取消收藏" : "收藏点位") {
                model.toggleFavorite(p)
                model.status = model.isFavorite(p) ? "已收藏：\(p.name)" : "已取消收藏：\(p.name)"
            }
            Button("编辑该点位") { editPoi = p }
            if p.isCustom {
                Button("删除该点位", role: .destructive) {
                    model.deletePoi(id: p.id)
                    model.status = "已删除：\(p.name)"
                }
            } else {
                Button("内置点位，长按图标可拖动自定义位置", systemImage: "info.circle") {}
                    .disabled(true)
            }
            Button("取消", role: .cancel) {}
        } message: { p in
            Text(String(format: "%@ · %@\n纬度 %.5f 经度 %.5f", p.name, p.type.label, p.lat, p.lon))
        }
    }
}

/// v2.27 弹窗组 4：电警点位管理页
///
/// 单独拆一个组而不是塞进 Group1~3：
/// Swift 的类型检查超时按表达式计预算，组越大越容易触发
/// "unable to type-check this expression in reasonable time"（v2.25 连续踩了 3 次）。
struct SheetGroup4Modifier: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var showCameraManage: Bool
    /// v2.27 开发者诊断页
    @Binding var showDiagnostics: Bool
    var camStore: PoliceCameraStore

    func body(content: Content) -> some View {
        content
        .sheet(isPresented: $showCameraManage) {
            CameraManageSheet(store: camStore, model: model)
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsSheet(model: model, camStore: camStore)
        }
    }
}


//
//  CameraTapSheet.swift
//  MotoNav
//
//  v2.27 从 ContentView.swift 拆出（优化建议 #2）
//
//  官方电警点详情卡
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

struct CameraTapSheet: View {
    let camera: PoliceCamera
    @ObservedObject var store: PoliceCameraStore
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    @State private var distText = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("点位详情")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 4) {
                Text(camera.name)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text("\(camera.type.title) · \(distText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(String(format: "纬度 %.5f  经度 %.5f", camera.lat, camera.lon))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            // 分享
            Button {
                PlaceShare.present(PlaceShare.payload(name: camera.name,
                                                      address: camera.district,
                                                      type: camera.type.title,
                                                      road: camera.dirs,
                                                      lat: camera.lat, lon: camera.lon))
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .font(.footnote.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            // 红色删除
            Button {
                store.delete(id: camera.id)
                model.status = "已删除「\(camera.name)」，地图上不再显示"
                onClose()
            } label: {
                Label("删除", systemImage: "trash")
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
            }
            if !camera.source.isEmpty {
                Text("来源：\(camera.source)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .presentationDetents([.height(370)])
        .onAppear {
            if let loc = model.currentLocation {
                let d = loc.distance(to: camera.coordinate)
                distText = d >= 1000
                    ? String(format: "距我 %.1f 公里", d / 1000.0)
                    : String(format: "距我 %d 米", Int(d))
            } else {
                distText = "尚未定位"
            }
        }
    }
}

/// v1.61 恢复：语音包设置（高德式：语音引擎 + 音色列表 + 喇叭试听 + 选中勾）
/// 入口："我的"→语音播报

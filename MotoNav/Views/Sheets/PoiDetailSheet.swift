//
//  PoiDetailSheet.swift
//  MotoNav
//
//  v2.27 从 ContentView.swift 拆出（优化建议 #2）
//
//  点位详情卡（分享 + 删除）
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
import UIKit

struct PoiDetailSheet: View {
    let poi: Poi
    @ObservedObject var model: AppModel
    let onClose: (Bool) -> Void
    @State private var distText = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("点位详情")
                    .font(.headline)
                Spacer()
                Button {
                    onClose(true)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 4) {
                Text(poi.name)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                Text("\(poi.type.label) · \(distText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(String(format: "纬度 %.5f  经度 %.5f", poi.lat, poi.lon))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            // v2.27（优化建议 #26）分享按钮分项 + 排版优化：
            //   · 坐标信息做成可一键复制（骑手常要发"这个路口在哪"给别人）
            //   · 分享拆成"分享文字"和"分享到高德/百度"两个入口：
            //     前者给微信/QQ 发文字，后者直接唤起对应地图 App
            HStack(spacing: 10) {
                // 复制坐标
                Button {
                    UIPasteboard.general.string = String(format: "%.6f, %.6f", poi.lat, poi.lon)
                    model.status = "已复制坐标"
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "doc.on.doc")
                            .font(.footnote)
                        Text("复制坐标")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                // 分享文字 + 链接（微信可正常接收）
                Button {
                    PlaceShare.present(PlaceShare.payload(name: poi.name,
                                                          address: "",
                                                          type: poi.type.label,
                                                          road: "",
                                                          lat: poi.lat, lon: poi.lon))
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.footnote)
                        Text("分享")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            // v2.26 新增红色删除按钮：删除后该抓拍点从地图上消失
            Button {
                model.deletePoi(id: poi.id)
                model.status = "已删除「\(poi.name)」，地图上不再显示"
                onClose(true)
            } label: {
                Label("删除", systemImage: "trash")
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(20)
        .presentationDetents([.height(370)])
        .onAppear {
            if let loc = model.currentLocation {
                let d = model.distance(to: poi, from: loc)
                distText = d >= 1000
                    ? String(format: "距我 %.1f 公里", d / 1000.0)
                    : String(format: "距我 %d 米", Int(d))
            } else {
                distText = "尚未定位"
            }
        }
    }
}

/// v2.26 官方电警点详情卡：只保留「分享」+「删除」
///
/// 与 PoiDetailSheet 的差别：
///   · 数据源是官方公示库（PoliceCamera），不是用户自建点位；
///   · 删除走 PoliceCameraStore 的删除表，重启后不会复活。

//
//  OfflineMapSheet.swift
//  MotoNav
//
//  v2.27 从 ContentView.swift 拆出（优化建议 #2）
//
//  离线地图
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

struct OfflineMapSheet: View {
    @ObservedObject var manager: OfflineMapManager
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var radius: Double = 10

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("范围", selection: $radius) {
                        Text("5 km").tag(5.0)
                        Text("10 km").tag(10.0)
                        Text("20 km").tag(20.0)
                        Text("40 km").tag(40.0)
                    }
                    .pickerStyle(.segmented)

                    Button {
                        guard let c = model.currentLocation else {
                            model.status = "请先定位再下载离线地图"
                            return
                        }
                        Task {
                            await manager.download(name: "当前位置 \(Int(radius))km",
                                                   lat: c.latitude, lon: c.longitude,
                                                   radiusKm: radius)
                        }
                    } label: {
                        HStack {
                            Label("下载当前位置周边", systemImage: "arrow.down.circle")
                            Spacer()
                            Text(manager.busy ? "下载中…" : "约 \(OfflineMapManager.estimateTileCount(radiusKm: radius)) 张")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(manager.busy)

                    if manager.busy {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: manager.progress)
                            Text(manager.progressText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button("取消下载", role: .destructive) { manager.cancel() }
                                .font(.caption)
                        }
                    }
                    if let e = manager.lastError {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("离线包会把该范围内的地图瓦片存到本机，进山没信号时仍有底图；下载后在线缓存也会复用这些瓦片，更省流量。")
                }

                Section("已下载") {
                    if manager.packs.isEmpty {
                        Text("暂无离线包").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(manager.packs) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.subheadline)
                                Text(p.subtitle).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                manager.delete(p)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("离线地图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// 组队骑行：队伍码 + 昵称，实时显示队友距离

//
//  FootprintSheet.swift
//  MotoNav
//
//  v2.27 从 ContentView.swift 拆出（优化建议 #2）
//
//  足迹列表
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

struct FootprintSheet: View {
    @ObservedObject var store: FootprintStore
    var onReplay: (Footprint) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var exporting: Footprint?

    var body: some View {
        NavigationStack {
            List {
                if store.items.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没有足迹").font(.headline)
                            Text("每次结束导航会自动存档：里程、时长、均速、最高速和轨迹。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section {
                        HStack {
                            statBlock("总里程", String(format: "%.1f km", Double(store.totalDistanceM) / 1000))
                            Divider()
                            statBlock("总时长", "\(store.totalDurationS / 3600) 小时")
                            Divider()
                            statBlock("记录", "\(store.items.count) 次")
                        }
                    }
                    Section("行程") {
                        ForEach(store.items) { f in
                            Button {
                                onReplay(f)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(f.destName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(f.dateText)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("\(f.distanceText) · \(f.durationText) · 均速 \(String(format: "%.0f", f.avgSpeed)) · 最高 \(String(format: "%.0f", f.maxSpeed)) km/h")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.remove(f.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    exporting = f
                                } label: {
                                    Label("导出", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("足迹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.items.isEmpty {
                        Button("清空", role: .destructive) { store.clear() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $exporting) { f in
                GPXShareSheet(items: [store.gpx(for: f)])
            }
        }
    }

    private func statBlock(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.bold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 离线地图：按当前位置下载指定半径的瓦片包

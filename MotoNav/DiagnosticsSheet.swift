//
//  DiagnosticsSheet.swift
//  MotoNav
//
//  v2.27 新增：开发者诊断页
//
//  优化建议 #24（内存与耗电应可见）+ #25（开发者诊断隐藏入口）
//
//  为什么做这个
//  ------------
//  骑行 App 的用户对自己手机的状态是有感知的 —— 手机发烫、掉电快、地图卡顿，
//  这些都会被归到"这个 App 有问题"。但开发者看不到用户的真实环境，
//  用户反馈时只能靠猜（"你是什么机型""是不是省电模式"）。
//
//  有了这个页面：
//  · 用户能自己看到内存占用、瓦片缓存大小、定位频率、电量消耗速率
//  · 用户反馈问题时，可以直接把这一页截图发过来 —— 里面就有定位坐标、坐标系、
//    最近的网络请求、瓦片命中/未命中数、最近的日志
//
//  入口是隐藏的：在「我的」页连点版本号 7 次。
//

import SwiftUI
import UIKit

/// v2.27 诊断页
struct DiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @ObservedObject var camStore: PoliceCameraStore
    /// 刷新计数（用于触发重算）
    @State private var tick = 0
    /// 上次采样时的电量
    @State private var lastBattery: Float = -1
    /// 上次采样时间
    @State private var lastSampleAt = Date()
    /// 电量消耗速率（%/小时）
    @State private var drainPerHour: Double = 0

    var body: some View {
        NavigationStack {
            List {
                // ── 设备 ────────────────────────────────────────
                Section("设备") {
                    row("机型", UIDevice.current.model)
                    row("系统", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    row("屏幕", "\(Int(UIScreen.main.bounds.width))×\(Int(UIScreen.main.bounds.height))")
                    row("定位授权", model.locationAuthText)
                    row("省电模式", model.powerSaving ? "已开启（降频+调暗）" : "未开启")
                    row("低电量模式", ProcessInfo.processInfo.isLowPowerModeEnabled ? "系统已开启" : "未开启")
                }

                // ── 内存与耗电 ──────────────────────────────────
                Section {
                    row("内存占用", formatBytes(memoryUsage()))
                    row("瓦片缓存", formatBytes(AmapTileRenderer.diskCacheSize()))
                    row("瓦片命中/未命中", "\(AmapTileRenderer.hitCount) / \(AmapTileRenderer.missCount)")
                    row("电量", String(format: "%.0f%%", (batteryLevel() * 100)))
                    row("耗电速率", drainPerHour > 0.5
                        ? String(format: "%.1f %%/小时", drainPerHour)
                        : "样本不足（再等几分钟）")
                    row("定位频率", model.navigating ? "导航中 2 米" : (model.isMoving ? "移动中 8 米" : "静止 25 米"))
                } header: {
                    Text("资源")
                } footer: {
                    Text("耗电速率需要采样两次以上才能算出来，等几分钟再回来看看。")
                }

                // ── 定位 ────────────────────────────────────────
                Section("定位") {
                    row("当前坐标", coordText(model.currentLocation))
                    row("坐标系", "WGS-84（显示前转 GCJ-02 喂给 MapKit）")
                    row("水平精度", model.locationAccuracy > 0
                        ? String(format: "%.0f 米", model.locationAccuracy) : "未知")
                    row("速度", String(format: "%.1f km/h", model.currentSpeed * 3.6))
                    row("当前道路", model.currentRoadName.isEmpty ? "未知" : model.currentRoadName)
                }

                // ── 路线与点位 ──────────────────────────────────
                Section("路线与点位") {
                    row("导航中", model.navigating ? "是" : "否")
                    row("路线折线点数", "\(model.route.count)")
                    row("转向步骤数", "\(model.routeTurns.count)")
                    row("已走过索引", "\(model.traveledIdx)")
                    row("自建点位", "\(model.pois.count)")
                    row("官方电警点", "\(camStore.all.count)")
                    row("已删除电警点", "\(camStore.deletedIds.count)")
                    row("已校准电警点", "\(camStore.adjustedCount)")
                    row("同步新增点位", "\(camStore.syncedExtra.count)")
                }

                // ── 最近日志 ────────────────────────────────────
                Section {
                    ForEach(Array(model.recentLogs.suffix(20).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if model.recentLogs.isEmpty {
                        Text("暂无日志").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("最近日志（最近 20 条）")
                } footer: {
                    Text("截图这一页发给开发者，能省掉来回问机型、问设置的来回。")
                }
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        tick += 1
                        sampleBattery()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear { sampleBattery() }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 采样

    private func sampleBattery() {
        let now = Date()
        let b = batteryLevel()
        if lastBattery >= 0 {
            let hours = now.timeIntervalSince(lastSampleAt) / 3600.0
            if hours > 0.001 {
                // 电池是百分比（0~1），下降为耗电
                let delta = lastBattery - b
                drainPerHour = max(0, delta / hours * 100)
            }
        }
        lastBattery = b
        lastSampleAt = now
    }

    private func batteryLevel() -> Float {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let lvl = UIDevice.current.batteryLevel
        return lvl < 0 ? 0 : lvl
    }

    private func memoryUsage() -> UInt64 {
        // 读 task_vm_info（取物理内存占用）
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    private func formatBytes(_ b: UInt64) -> String {
        let f = Double(b) / 1024.0 / 1024.0
        return String(format: "%.1f MB", f)
    }

    private func coordText(_ c: CLLocationCoordinate2D?) -> String {
        guard let c else { return "未定位" }
        return String(format: "%.6f, %.6f", c.latitude, c.longitude)
    }
}

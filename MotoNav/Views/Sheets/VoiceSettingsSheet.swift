//
//  VoiceSettingsSheet.swift
//  MotoNav
//
//  v2.27 从 ContentView.swift 拆出（优化建议 #2）
//
//  语音包设置
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

struct VoiceSettingsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let testText = "前方 500 米右转，进入包公大道，请注意安全"
    private let voices: [(vcn: String, name: String, sub: String, icon: String)] = [
        // v1.80 语音包统一列表：本地内置（vcn=""）+ 讯飞已授权发音人（实测合成成功）
        ("", "本地内置 · 默认中文女声", "iOS 内置中文语音，无需联网", "iphone"),
        ("xiaoyan", "普通话女声 · 晓燕", "标准普通话，字正腔圆", "speaker.wave.2.fill"),
        ("xiaoyu", "普通话女声 · 晓宇", "甜美普通话女声", "speaker.wave.2.fill"),
        ("xiaomei", "普通话女声 · 小美", "温柔普通话女声", "speaker.wave.2.fill"),
        ("xiaoqiang", "普通话男声 · 小强", "沉稳普通话男声", "speaker.wave.2.fill"),
        ("xiaorong", "四川话女声 · 小蓉", "亲切川味，导航更有味道", "speaker.wave.3.fill"),
        ("xiaoyue", "粤语女声 · 晓月", "标准粤语女声", "speaker.wave.2.fill"),
        ("x4_xiaolu", "普通话女声 · 讯飞小露", "特色发音人，清亮女声", "sparkles"),
        ("x4_xiaorong", "四川话女声 · 讯飞小蓉", "特色发音人，川味十足", "sparkles"),
        ("x4_yezi", "四川话女声 · 叶子", "清亮川腔，推荐", "sparkles"),
        ("x4_lingbosong", "普通话男声 · 聆伯松", "特色发音人，磁性男声", "sparkles"),
        ("x4_lingxiaoxuan_wenrou", "普通话女声 · 聆小璇-温柔", "特色发音人，温柔女声", "sparkles")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(voices, id: \.vcn) { v in
                        HStack(spacing: 8) {
                            Image(systemName: v.icon)
                                .foregroundStyle(v.vcn.isEmpty ? .gray : .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.name)
                                    .foregroundStyle(.primary)
                                Text(v.sub)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.speak(testText)
                            } label: {
                                Image(systemName: "play.circle")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.borderless)
                            if v.vcn.isEmpty ? !model.xfEnabled : (model.xfEnabled && model.xfVcn == v.vcn) {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if v.vcn.isEmpty {
                                UserDefaults.standard.set(false, forKey: "xfEnabled")
                            } else {
                                UserDefaults.standard.set(true, forKey: "xfEnabled")
                                UserDefaults.standard.set(v.vcn, forKey: "xfVcn")
                            }
                            model.speak("语音已切换为\(v.name)")
                        }
                    }
                } header: {
                    Text("语音包")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !model.xfDiag.isEmpty {
                            Text("诊断：\(model.xfDiag)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Text("本地内置无需联网；讯飞音色为你的应用已授权发音人，需联网合成，新增音色请到讯飞控制台「发音人授权管理」开通。")
                    }
                }
            }
            .navigationTitle("语音播报")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(430)])
    }
}

/// v1.82 列表行左滑删除（联想"常搜"项用）：左拉露出右侧红色删除按钮块（高度同行），滑过一半触发删除

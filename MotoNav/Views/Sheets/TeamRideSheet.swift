//
//  TeamRideSheet.swift
//  MotoNav
//
//  v2.27 从 ContentView.swift 拆出（优化建议 #2）
//
//  组队骑行
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

struct TeamRideSheet: View {
    @ObservedObject var team: TeamRide
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var nickname = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("昵称（如：老王）", text: $nickname)
                    TextField("队伍码（4-6 位，同伴输入同一个）", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    HStack {
                        Button {
                            code = TeamRide.randomCode()
                        } label: {
                            Label("随机生成", systemImage: "dice")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        if team.active {
                            Button("退出队伍", role: .destructive) {
                                team.stop()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("开始组队") {
                                team.start(code: code, nickname: nickname)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(code.trimmingCharacters(in: .whitespaces).count < 4)
                        }
                    }
                } footer: {
                    Text("把队伍码发给同伴，各自输入同一个码即可互相看到位置（约 6 秒刷新一次）。仅共享位置与速度，不做长期存储。")
                }

                if team.active {
                    Section("队伍 \(team.code)") {
                        if let e = team.lastError {
                            Text(e).font(.caption).foregroundStyle(.red)
                        }
                        ForEach(team.members) { m in
                            HStack {
                                Image(systemName: m.name == team.nickname ? "location.fill" : "person.fill")
                                    .foregroundStyle(m.name == team.nickname ? .blue : .teal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name + (m.name == team.nickname ? "（我）" : ""))
                                        .font(.subheadline)
                                    Text("\(String(format: "%.0f", m.speedKph)) km/h · \(m.ageText)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        if team.members.count <= 1 {
                            Text("等待同伴加入…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("组队骑行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}


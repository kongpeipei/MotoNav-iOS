import SwiftUI

/// 极简电子眼播报器主界面：打开即监听，接近违法拍照点自动语音提醒
struct ContentView: View {
    @EnvironmentObject private var engine: AlertEngine

    private let distanceOptions: [Double] = [300, 500, 800, 1000]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusBar
                    nearestCard
                    backgroundHint
                    announcementsSection
                    settingsSection
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("电子眼卫士")
        }
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(engine.isMonitoring ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(engine.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                engine.isMonitoring
                    ? (engine.stop())
                    : (engine.start())
            } label: {
                Text(engine.isMonitoring ? "暂停" : "开始监听")
                    .font(.footnote.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(engine.isMonitoring ? Color.orange : Color.blue,
                                in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 最近点位卡片

    private var nearestCard: some View {
        VStack(spacing: 8) {
            if let p = engine.nearest, engine.nearestDistance < .greatestFiniteMagnitude {
                Text(distanceText(engine.nearestDistance))
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(engine.nearestDistance <= engine.warnDistance ? .red : .primary)
                HStack(spacing: 6) {
                    Image(systemName: p.type.icon)
                    Text(p.type.label)
                        .font(.headline)
                    Text("· \(p.name)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(engine.nearestDistance <= engine.warnDistance
                     ? "即将播报：\(p.type.voiceText)"
                     : "接近 \(Int(engine.warnDistance)) 米内自动语音提醒")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "location.magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("定位中，附近暂无违法拍照点")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("载入 \(engine.pois.count) 个点位 · 接近自动播报")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 后台运行提示

    private var backgroundHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(.yellow)
            Text("后台运行：打开一次后，切后台 / 锁屏仍会持续定位并语音提醒。需在 系统设置→隐私与安全性→定位服务→电子眼卫士 中选择「始终」")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 播报记录

    private var announcementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近播报")
                .font(.headline)
            if engine.announcements.isEmpty {
                Text("暂无播报记录，接近点位后自动出现")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ForEach(engine.announcements) { a in
                    HStack(spacing: 8) {
                        Image(systemName: a.type.icon)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.text)
                                .font(.subheadline)
                                .lineLimit(2)
                            Text("\(a.time.formatted(date: .omitted, time: .shortened)) · 触发时约 \(a.distance) 米")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    if a.id != engine.announcements.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("播报触发距离：\(Int(engine.warnDistance)) 米")
                    .font(.subheadline)
                Picker("播报距离", selection: $engine.warnDistance) {
                    ForEach(distanceOptions, id: \.self) { d in
                        Text("\(Int(d))m").tag(d)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("播报类型")
                    .font(.subheadline)
                ForEach(PoiType.allCases, id: \.self) { t in
                    Toggle(isOn: binding(for: t)) {
                        HStack(spacing: 6) {
                            Image(systemName: t.icon)
                            Text(t.label)
                        }
                        .font(.subheadline)
                    }
                }
            }

            Button {
                engine.testSpeak()
            } label: {
                Text("测试语音播报")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func binding(for t: PoiType) -> Binding<Bool> {
        Binding(
            get: { engine.enabledTypes.contains(t) },
            set: { on in
                if on { engine.enabledTypes.insert(t) } else { engine.enabledTypes.remove(t) }
            }
        )
    }

    private func distanceText(_ d: Double) -> String {
        d >= 1000 ? String(format: "%.1f 公里", d / 1000) : "\(Int(d)) 米"
    }
}

import SwiftUI
import UIKit
import CoreLocation
import UniformTypeIdentifiers

/// #3 点位编辑页面：查看 / 添加（支持交叉口 geocoder）/ 删除（二次确认）
struct PoiEditorView: View {
    @EnvironmentObject var engine: AlertEngine
    @Environment(\.dismiss) private var dismiss

    @State private var showAddForm = false
    @State private var poiToDelete: Poi?
    @State private var builtinToDelete: Poi?
    @State private var poiToEdit: Poi?
    @State private var showRestoreBuiltinConfirm = false
    /// 持有导入协调器：UIDocumentPicker 的 delegate 不会被系统强引用，临时对象会被提前释放导致回调丢失
    @State private var importer: ImportCoordinator?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showAddForm = true
                    } label: {
                        Label("添加新点位", systemImage: "plus.circle.fill")
                            .foregroundStyle(.blue)
                    }
                    Button {
                        performImport()
                    } label: {
                        Label("从 JSON 文件导入", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        performExport()
                    } label: {
                        Label("导出全部点位为 JSON", systemImage: "square.and.arrow.up")
                    }
                    // v1.20 一键恢复：清空删除/改名/半径/开关台账，回到出厂默认
                    Button {
                        showRestoreBuiltinConfirm = true
                    } label: {
                        Label("恢复全部内置点位", systemImage: "arrow.uturn.backward.circle")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("操作")
                }

                // v1.8：自定义点位置顶，方便修改/查看
                Section {
                    if engine.userPois.isEmpty {
                        Text("还没有自定义点位，点击上方「添加新点位」开始")
                            .foregroundStyle(.tertiary)
                            .font(.footnote)
                    } else {
                        // v1.21 渲染层去重：历史重复 id 折叠为一条，防 ForEach 断言崩溃
                        ForEach(engine.deduplicated(engine.userPois)) { p in
                            PoiRow(poi: p, editable: true) { action in
                                handleAction(action, for: p, builtin: false)
                            }
                        }
                    }
                } header: {
                    Text("自定义点位（\(engine.deduplicated(engine.userPois).count) 个）")
                } footer: {
                    Text("自定义点位持久化在本地，卸载 App 会清除")
                }

                // v1.8：内置点位可修改（名称/半径/开关）或删除，坐标与类型固定
                Section {
                    if engine.builtinPois.isEmpty {
                        Text("无内置点位（已全部删除）")
                            .foregroundStyle(.tertiary)
                    } else {
                        // v1.21 渲染层去重：补丁改名等场景可能产生撞 id，折叠为一条防崩溃
                        ForEach(engine.deduplicated(engine.builtinPois)) { p in
                            PoiRow(poi: p, editable: true) { action in
                                handleAction(action, for: p, builtin: true)
                            }
                        }
                    }
                } header: {
                    Text("内置点位（显示 \(engine.deduplicated(engine.builtinPois).count) / 共 \(engine.bundledPois.count) 个）")
                } footer: {
                    Text("内置点位可改名称、半径、开关，也可删除；坐标与类型固定。App 升级后可恢复默认。")
                }
            }
            .navigationTitle("点位管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddForm) {
                AddPoiView { newPoi in
                    engine.addUserPoi(newPoi)
                }
            }
            .sheet(item: $poiToEdit) { p in
                EditPoiSheet(poi: p) { updated in
                    if engine.bundledPois.contains(where: { $0.id == p.id }) {
                        engine.updateBuiltinPoi(updated)
                    } else {
                        engine.updateUserPoi(updated)
                    }
                }
            }
            .alert(item: $poiToDelete) { p in
                Alert(
                    title: Text("删除自定义点位"),
                    message: Text("确定要删除「\(p.name)」吗？此操作无法撤销。"),
                    primaryButton: .destructive(Text("删除")) {
                        engine.deleteUserPoi(id: p.id)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
            .alert(item: $builtinToDelete) { p in
                Alert(
                    title: Text("删除内置点位"),
                    message: Text("确定要删除内置点位「\(p.name)」吗？可在「操作 → 恢复全部内置点位」找回。"),
                    primaryButton: .destructive(Text("删除")) {
                        engine.deleteBuiltinPoi(id: p.id)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
            .alert("恢复全部内置点位", isPresented: $showRestoreBuiltinConfirm) {
                Button("恢复", role: .destructive) { engine.restoreAllBuiltinPois() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("将清空所有对内置点位的删除、改名、半径与开关修改，恢复到出厂默认。")
            }
        }
    }

    // MARK: - 动作处理

    private func handleAction(_ action: PoiRowAction, for poi: Poi, builtin: Bool) {
        switch action {
        case .delete:
            if builtin { builtinToDelete = poi } else { poiToDelete = poi }
        case .toggle:
            if builtin {
                engine.toggleBuiltinPoi(poi)
            } else {
                engine.toggleUserPoi(id: poi.id)
            }
        case .edit:
            poiToEdit = poi
        }
    }

    private func performExport() {
        guard let data = engine.exportAllPois() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poi_export.json")
        try? data.write(to: url)
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        currentTopViewController()?.present(picker, animated: true)
    }

    private func performImport() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json])
        let coordinator = ImportCoordinator(engine: engine)
        importer = coordinator
        picker.delegate = coordinator
        currentTopViewController()?.present(picker, animated: true)
    }
}

// MARK: - 行组件

enum PoiRowAction { case delete, toggle, edit }

struct PoiRow: View {
    let poi: Poi
    var editable: Bool = false
    var onAction: ((PoiRowAction) -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: poi.type.icon)
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(poi.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(poi.type.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("radius \(Int(poi.radiusM))m")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.4f,%.4f", poi.latitude, poi.longitude))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if editable {
                Button {
                    onAction?(.edit)
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                Toggle("", isOn: Binding(
                    get: { poi.enabled },
                    set: { _ in onAction?(.toggle) }
                ))
                .labelsHidden()
                Button(role: .destructive) {
                    onAction?(.delete)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 编辑弹窗（v1.8：内置/自定义通用，坐标与类型固定）

struct EditPoiSheet: View {
    @Environment(\.dismiss) private var dismiss
    let poi: Poi
    let onSave: (Poi) -> Void

    @State private var name: String
    @State private var radiusM: Double
    @State private var enabled: Bool

    init(poi: Poi, onSave: @escaping (Poi) -> Void) {
        self.poi = poi
        self.onSave = onSave
        _name = State(initialValue: poi.name)
        _radiusM = State(initialValue: poi.radiusM)
        _enabled = State(initialValue: poi.enabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("点位名称", text: $name, prompt: Text("例：蒙城路与北一环路交叉口"))
                    HStack {
                        Text("类型")
                        Spacer()
                        Label(poi.type.label, systemImage: poi.type.icon)
                            .foregroundStyle(.secondary)
                    }
                    Stepper(value: $radiusM, in: 100...2000, step: 50) {
                        Text("预警半径：\(Int(radiusM)) 米")
                    }
                    Toggle("启用提醒", isOn: $enabled)
                }

                Section("位置（不可修改）") {
                    Text(String(format: "%.6f, %.6f", poi.latitude, poi.longitude))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Text("保存修改")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("编辑点位")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func save() {
        var p = poi
        p.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.radiusM = radiusM
        p.enabled = enabled
        onSave(p)
        dismiss()
    }
}

// MARK: - 导入协调器

final class ImportCoordinator: NSObject, UIDocumentPickerDelegate {
    let engine: AlertEngine
    init(engine: AlertEngine) { self.engine = engine }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // v1.4：从「文件」/iCloud/第三方网盘选中的文件属于安全作用域资源，
        // 不申请访问权限时 Data(contentsOf:) 会失败（表现为“选完文件没反应”）
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let result = try engine.importPois(from: data)
            showAlert(title: "导入完成",
                      message: "新增 \(result.added) 个点位，跳过 \(result.skipped) 条重复或无效数据")
        } catch {
            showAlert(title: "导入失败", message: error.localizedDescription)
        }
    }

    /// 选择器还在收起动画中时从根控制器 present 会静默失败，延后到收起完成再弹
    private func showAlert(title: String, message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            currentTopViewController()?.present(alert, animated: true)
        }
    }
}

/// 取当前最上层控制器（v1.4：沿 presentedViewController 链向上，避免 sheet/选择器叠层时从根控制器弹出失败），页面与导入协调器共用
private func currentTopViewController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }) else { return nil }
    var vc = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?.rootViewController
    while let presented = vc?.presentedViewController, !presented.isBeingDismissed {
        vc = presented
    }
    return vc
}

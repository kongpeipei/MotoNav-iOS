import SwiftUI
import CoreLocation

/// #3 点位编辑页面：查看 / 添加（支持交叉口 geocoder）/ 删除（二次确认）
struct PoiEditorView: View {
    @EnvironmentObject var engine: AlertEngine
    @Environment(\.dismiss) private var dismiss

    @State private var showAddForm = false
    @State private var poiToDelete: Poi?

    private let columns = [GridItem(.adaptive(minimum: 80))]

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
                } header: {
                    Text("操作")
                }

                Section("内置点位（共 \(engine.bundledPois.filter { $0.enabled }.count) 个）") {
                    ForEach(engine.bundledPois.filter { $0.enabled }) { p in
                        PoiRow(poi: p)
                    }
                    if engine.bundledPois.filter({ $0.enabled }).isEmpty {
                        Text("无内置点位")
                            .foregroundStyle(.tertiary)
                    }
                } footer: {
                    Text("内置点位不可修改，由 App 提供")
                }

                Section {
                    if engine.userPois.isEmpty {
                        Text("还没有自定义点位，点击上方「添加新点位」开始")
                            .foregroundStyle(.tertiary)
                            .font(.footnote)
                    } else {
                        ForEach(engine.userPois) { p in
                            PoiRow(poi: p, editable: true) { action in
                                handleUserPoiAction(action, for: p)
                            }
                        }
                    }
                } header: {
                    Text("自定义点位（\(engine.userPois.count) 个）")
                } footer: {
                    Text("自定义点位持久化在本地，卸载 App 会清除")
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
            .alert(item: $poiToDelete) { p in
                Alert(
                    title: Text("删除点位"),
                    message: Text("确定要删除「\(p.name)」吗？此操作无法撤销。"),
                    primaryButton: .destructive(Text("删除")) {
                        engine.deleteUserPoi(id: p.id)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
            .fileImporter(isPresented: .constant(false), allowedContentTypes: [.json]) { _ in }
        }
    }

    // MARK: - 动作处理

    private func handleUserPoiAction(_ action: PoiRowAction, for poi: Poi) {
        switch action {
        case .delete:
            poiToDelete = poi
        case .toggle:
            engine.toggleUserPoi(id: poi.id)
        }
    }

    private func performExport() {
        guard let data = engine.exportAllPois() else { return }
        // 通过 UIDocumentPicker 导出
        let picker = UIDocumentPickerViewController(forExporting: [data as NSData], asCopy: true)
        UIApplication.shared.windows.first?.rootViewController?.present(picker, animated: true)
    }

    private func performImport() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json])
        picker.delegate = ImportCoordinator(engine: engine)
        UIApplication.shared.windows.first?.rootViewController?.present(picker, animated: true)
    }
}

// MARK: - 行组件

enum PoiRowAction { case delete, toggle }

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

// MARK: - 导入协调器

final class ImportCoordinator: NSObject, UIDocumentPickerDelegate {
    let engine: AlertEngine
    init(engine: AlertEngine) { self.engine = engine }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            let data = try Data(contentsOf: url)
            try engine.importPois(from: data)
        } catch {
            // 简易提示
            let alert = UIAlertController(title: "导入失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            UIApplication.shared.windows.first?.rootViewController?.present(alert, animated: true)
        }
    }
}

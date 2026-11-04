import SwiftUI
import CoreLocation

/// 添加点位表单：支持手动坐标 或 输入道路交叉口地址（CLGeocoder 解析）
struct AddPoiView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (Poi) -> Void

    @State private var name: String = ""
    @State private var type: PoiType = .RED_LIGHT
    @State private var radiusM: Double = 500
    @State private var useAddress: Bool = true
    @State private var addressInput: String = ""
    @State private var latText: String = ""
    @State private var lonText: String = ""
    @State private var geocoding = false
    @State private var geocodeError: String?

    private let formatter = NumberFormatter()

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("点位名称", text: $name, prompt: Text("例：蒙城路与北一环路交叉口"))
                    Picker("类型", selection: $type) {
                        ForEach(PoiType.allCases, id: \.self) { t in
                            HStack {
                                Image(systemName: t.icon)
                                Text(t.label)
                            }
                            .tag(t)
                        }
                    }
                    Stepper(value: $radiusM, in: 100...2000, step: 50) {
                        Text("预警半径：\(Int(radiusM)) 米")
                    }
                }

                Section("位置") {
                    Toggle("通过地址解析（推荐）", isOn: $useAddress)

                    if useAddress {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("道路交叉口地址", text: $addressInput,
                                      prompt: Text("例：蒙城路和北一环路交叉口"))
                                .textInputAutocapitalization(.never)

                            HStack {
                                Button {
                                    geocode()
                                } label: {
                                    HStack {
                                        if geocoding { ProgressView() }
                                        Image(systemName: "map")
                                        Text(geocoding ? "解析中…" : "解析坐标")
                                    }
                                }
                                .disabled(addressInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || geocoding)

                                Spacer()

                                if let lat = Double(latText), let lon = Double(lonText),
                                   lat != 0 || lon != 0 {
                                    Text(String(format: "%.5f, %.5f", lat, lon))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let err = geocodeError {
                                Label(err, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    } else {
                        HStack {
                            TextField("纬度", text: $latText)
                                .keyboardType(.decimalPad)
                            TextField("经度", text: $lonText)
                                .keyboardType(.decimalPad)
                        }
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        Text("保存点位")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canSubmit)
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("添加点位")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var canSubmit: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let lat = Double(latText), let lon = Double(lonText) else { return false }
        return CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    private func geocode() {
        let address = addressInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        geocoding = true
        geocodeError = nil

        let geocoder = CLGeocoder()
        // 对"X路与Y路交叉口"这类输入加上合肥限定，避免解析到其他城市
        let cityHinted = address.contains("市") || address.contains("省") ? address : "合肥 " + address

        geocoder.geocodeAddressString(cityHinted) { placemarks, error in
            DispatchQueue.main.async {
                geocoding = false
                if let pm = placemarks?.first, let loc = pm.location {
                    latText = String(format: "%.6f", loc.coordinate.latitude)
                    lonText = String(format: "%.6f", loc.coordinate.longitude)
                    // 自动用解析结果填充名称（如果用户没填）
                    if self.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        self.name = pm.name ?? address
                    }
                } else if let e = error {
                    geocodeError = "解析失败：\(e.localizedDescription)"
                } else {
                    geocodeError = "未找到匹配位置，请尝试更详细的地址（如加上城市名）"
                }
            }
        }
    }

    private func submit() {
        guard let lat = Double(latText), let lon = Double(lonText) else { return }
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard CLLocationCoordinate2DIsValid(coord) else { return }

        let poi = Poi(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type,
            latitude: lat,
            longitude: lon,
            radiusM: radiusM,
            enabled: true
        )
        onAdd(poi)
        dismiss()
    }
}

import CarPlay
import AVFoundation

/// CarPlay 场景代理：
/// 车机连接后，在 CarPlay 屏幕显示地图模板 + 附近点位标注；
/// 手机端触发接近提醒时，同步弹出车载警示条并语音播报。
/// 前提：工程已带 com.apple.developer.carplay-maps entitlement 且经 Apple 审批。
@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate, CPMapTemplateDelegate {
    private var interfaceController: CPInterfaceController?
    private var mapTemplate: CPMapTemplate?
    private let speech = AVSpeechSynthesizer()

    // MARK: - 连接/断开

    nonisolated func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        Task { @MainActor in
            self.setup(interfaceController: interfaceController)
        }
    }

    nonisolated func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        Task { @MainActor in
            self.interfaceController = nil
            self.mapTemplate = nil
            NotificationCenter.default.removeObserver(self)
        }
    }

    private func setup(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        let map = CPMapTemplate()
        map.mapDelegate = self
        map.leadingNavigationBarButtons = [makeNearbyListButton()]
        map.trailingNavigationBarButtons = [makeVoiceButton()]
        self.mapTemplate = map

        interfaceController.setRootTemplate(map, animated: false, completion: nil)
        refreshAnnotations()
        observeAlerts()
    }

    // MARK: - 地图标注同步

    private func refreshAnnotations() {
        guard let map = mapTemplate else { return }
        for a in map.annotations {
            map.removeAnnotation(a)
        }
        for p in AppModel.shared.nearbyPois(withinM: 8000) {
            let ann = CPMapAnnotation(
                coordinate: p.coordinate,
                title: "\(p.type.label) \(p.name)",
                subtitle: nil,
                image: nil)
            map.addAnnotation(ann)
        }
    }

    private func observeAlerts() {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onAlert(_:)),
            name: .motoAlert, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onPoisChanged),
            name: .motoPoisChanged, object: nil)
    }

    @objc private func onPoisChanged() {
        refreshAnnotations()
    }

    @objc private func onAlert(_ note: Notification) {
        guard let p = note.object as? Poi, let controller = interfaceController else { return }
        let msg = "\(p.type.voicePrefix)，\(p.name)"
        speak(msg)
        let alert = CPAlertTemplate(
            titleVariants: [p.type.voicePrefix, p.name],
            actions: [CPAlertAction(title: "知道了", style: .default) { _ in }])
        controller.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - 车机按钮

    private func makeNearbyListButton() -> CPBarButton {
        CPBarButton(title: "附近点位") { [weak self] _ in
            Task { @MainActor in self?.showNearbyList() }
        }
    }

    private func makeVoiceButton() -> CPBarButton {
        CPBarButton(title: "播报") { [weak self] _ in
            Task { @MainActor in
                let count = AppModel.shared.nearbyPois(withinM: 3000).count
                self?.speak("前方三公里内有\(count)个提醒点位，请规范骑行")
            }
        }
    }

    private func showNearbyList() {
        guard let controller = interfaceController else { return }
        let groups = PoiType.allCases.compactMap { type -> CPListSection? in
            let items = AppModel.shared.nearbyPois(withinM: 8000)
                .filter { $0.type == type }
                .map { p in
                    CPListItem(text: p.name, detailText: p.type.label) { [weak self] _, _ in
                        Task { @MainActor in self?.showPoiDetail(p) }
                    }
                }
            guard !items.isEmpty else { return nil }
            return CPListSection(items: items, header: type.label)
        }
        let list = CPListTemplate(title: "附近点位", sections: groups)
        controller.pushTemplate(list, animated: true, completion: nil)
    }

    private func showPoiDetail(_ p: Poi) {
        guard let controller = interfaceController else { return }
        let alert = CPAlertTemplate(
            titleVariants: [p.name, "\(p.type.label) · 半径\(Int(p.radiusM))米", p.note],
            actions: [
                CPAlertAction(title: "播报", style: .default) { [weak self] _ in
                    Task { @MainActor in self?.speak("\(p.type.voicePrefix)，\(p.name)") }
                },
                CPAlertAction(title: "关闭", style: .cancel) { _ in }
            ])
        controller.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - 语音

    private func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.5
        speech.speak(u)
    }
}

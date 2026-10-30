import CarPlay
import AVFoundation

/// CarPlay 场景代理：
/// 车机连接后显示地图模板；手机端触发接近提醒时，弹出车载警示条并语音播报；
/// 「附近点位」按钮列出 8km 内点位，可查看详情并播报。
/// 前提：工程已带 com.apple.developer.carplay-maps entitlement 且经 Apple 审批。
@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate, CPListTemplateDelegate {
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
        map.leadingNavigationBarButtons = [makeNearbyListButton()]
        map.trailingNavigationBarButtons = [makeVoiceButton()]
        self.mapTemplate = map

        interfaceController.setRootTemplate(map, animated: false, completion: nil)
        observeAlerts()
    }

    // MARK: - 提醒监听

    private func observeAlerts() {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onAlert(_:)),
            name: .motoAlert, object: nil)
    }

    @objc private func onAlert(_ note: Notification) {
        guard let p = note.object as? Poi, let controller = interfaceController else { return }
        speak("前方\(p.type.voicePrefix)，\(p.name)，请提前减速、注意信号灯")
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
                .map { CPListItem(text: $0.name, detailText: $0.type.label) }
            guard !items.isEmpty else { return nil }
            return CPListSection(items: items, header: type.label, sectionIndexTitle: nil)
        }
        let list = CPListTemplate(title: "附近点位", sections: groups)
        list.delegate = self
        controller.pushTemplate(list, animated: true, completion: nil)
    }

    // MARK: - CPListTemplateDelegate

    nonisolated func listTemplate(
        _ listTemplate: CPListTemplate,
        didSelect item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            let name = item.text ?? ""
            self.speak("\(name)，请规范骑行")
            self.showPoiDetail(name: name)
            completionHandler()
        }
    }

    private func showPoiDetail(name: String) {
        guard let controller = interfaceController else { return }
        let alert = CPAlertTemplate(
            titleVariants: [name, "前方提醒点位"],
            actions: [
                CPAlertAction(title: "播报", style: .default) { [weak self] _ in
                    Task { @MainActor in self?.speak("\(name)，请规范骑行") }
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

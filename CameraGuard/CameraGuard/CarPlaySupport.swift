import Foundation
import AVFoundation
import MediaPlayer

/// v1.10 CarPlay（方案A：音频类）支持。
/// CarPlay 只对音频类应用提供「连接自动恢复播放 + 音频栏卡片」，没有自由悬浮层 API；
/// 本文件负责：静音占位流（让系统认为正在播放，连接 CarPlay 时自动恢复）、
/// Now Playing 状态卡片、CarPlay 连接检测（AVAudioSession 路由变化）。
final class CarPlaySupport {

    private init() {}

    // MARK: - 静音占位流

    /// 持续播放静音循环，使 App 处于「正在播放」状态：
    /// CarPlay 连接时系统自动恢复最近播放的音频应用（即自动进入监听），播报语音随后走车载音响。
    private static var silencePlayer: AVAudioPlayer?

    static func startSilenceStream() {
        guard silencePlayer == nil,
              let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0        // 音量 0，但系统仍视为「正在播放」，满足 CarPlay 自动恢复条件
            p.prepareToPlay()
            if p.play() {
                silencePlayer = p
                updateNowPlaying(title: nil)
            }
        } catch {
            silencePlayer = nil
        }
    }

    static func stopSilenceStream() {
        silencePlayer?.stop()
        silencePlayer = nil
    }

    // MARK: - Now Playing（CarPlay 音频栏卡片）

    /// 刷新 CarPlay / 锁屏的音频卡片信息；title 为 nil 时按监听状态自动生成
    static func updateNowPlaying(title: String? = nil) {
        let monitoring = title == nil ? isMonitoringSnapshot : title == "电子眼卫士 · 监听中"
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title ?? (monitoring ? "电子眼卫士 · 监听中" : "电子眼卫士 · 已暂停"),
            MPMediaItemPropertyArtist: pointsCountSnapshot > 0 ? "已载入 \(pointsCountSnapshot) 个点位" : "接近抓拍点自动语音提醒",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPMediaItemPropertyPlaybackDuration: 1,
            MPNowPlayingInfoPropertyPlaybackRate: monitoring ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 由 AlertEngine 同步的监听状态快照（避免强耦合，CarPlaySupport 只做展示）
    static var isMonitoringSnapshot = false
    static var pointsCountSnapshot = 0

    // MARK: - CarPlay 连接检测

    /// 是否已通过 CarPlay 车机音频端口输出
    static func isConnectedToCarPlay() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }
}

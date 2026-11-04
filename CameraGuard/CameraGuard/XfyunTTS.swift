import Foundation
import CryptoKit
import AVFoundation

/// 讯飞在线语音合成（WebSocket v2 协议）
/// 文档：https://www.xfyun.cn/doc/tts/online_tts/API.html
/// 鉴权：api_key + HMAC-SHA256(api_secret, "host\ndate\nrequest-line")
final class XfyunTTS: NSObject, AVAudioPlayerDelegate {

    private let appID: String
    private let apiKey: String
    private let apiSecret: String
    private let vcn: String

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var audioData = Data()
    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?
    private var finished = false

    init(appID: String, apiKey: String, apiSecret: String, vcn: String) {
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiSecret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.vcn = vcn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "xiaoyan" : vcn
        super.init()
    }

    var isConfigured: Bool {
        !appID.isEmpty && !apiKey.isEmpty && !apiSecret.isEmpty
    }

    func speak(_ text: String, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        self.finished = false
        audioData = Data()
        player?.stop()
        guard isConfigured, !text.isEmpty else { complete(); return }
        connect(text)
    }

    func stop() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        player?.stop()
    }

    // MARK: - 连接与发送

    private func connect(_ text: String) {
        let host = "tts-api.xfyun.cn"
        let path = "/v2/tts"
        let dateStr = Self.rfc1123Date()

        guard let url = URL(string: "wss://\(host)\(path)") else { complete(); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        let signOrigin = "host: \(host)\ndate: \(dateStr)\nGET \(path) HTTP/1.1"
        let signature = Self.hmacSHA256(key: apiSecret, message: signOrigin).base64EncodedString()
        let authOrigin = "api_key=\"\(apiKey)\", algorithm=\"hmac-sha256\", headers=\"host date request-line\", signature=\"\(signature)\""
        let authorization = Data(authOrigin.utf8).base64EncodedString()

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(dateStr, forHTTPHeaderField: "Date")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: request)
        webSocket?.resume()

        let business: [String: Any] = [
            "aue": "lame",                       // mp3 音频，便于 AVAudioPlayer 直接播放
            "auf": "audio/L16;rate=16000",
            "vcn": vcn,
            "speed": 50,
            "volume": 60,
            "pitch": 50,
            "tte": "UTF8"
        ]
        let payload: [String: Any] = [
            "common": ["app_id": appID],
            "business": business,
            "data": ["status": 2, "text": Data(text.utf8).base64EncodedString()]
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: json, encoding: .utf8) else { complete(); return }

        webSocket?.send(.string(jsonStr)) { [weak self] error in
            if error != nil { self?.finishPlay() } else { self?.receiveLoop() }
        }
    }

    // MARK: - 接收音频帧

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.audioData.append(data)
                    self.receiveLoop()
                case .string:
                    // 结束标记帧（data.status == 2）
                    self.finishPlay()
                @unknown default:
                    self.finishPlay()
                }
            case .failure:
                // 服务端关闭连接 = 数据流结束
                self.finishPlay()
            }
        }
    }

    // MARK: - 播放 & 收尾

    private func finishPlay() {
        guard !audioData.isEmpty else { complete(); return }
        do {
            player = try AVAudioPlayer(data: audioData, fileTypeHint: AVFileType.mp3.rawValue)
            player?.delegate = self
            player?.volume = 1.0
            player?.play()
        } catch {
            complete()
        }
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        webSocket?.cancel(with: .goingAway, reason: nil)
        onFinish?()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        complete()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        complete()
    }

    // MARK: - 工具

    static func rfc1123Date() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: Date())
    }

    static func hmacSHA256(key: String, message: String) -> Data {
        let k = SymmetricKey(data: Data(key.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: k)
        return Data(code)
    }
}
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
    private var onNoAudio: (() -> Void)?
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

    func speak(_ text: String, onFinish: @escaping () -> Void, onNoAudio: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onNoAudio = onNoAudio
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

        let signOrigin = "host: \(host)\ndate: \(dateStr)\nGET \(path) HTTP/1.1"
        let signature = Self.hmacSHA256(key: apiSecret, message: signOrigin).base64EncodedString()
        let authOrigin = "api_key=\"\(apiKey)\", algorithm=\"hmac-sha256\", headers=\"host date request-line\", signature=\"\(signature)\""
        let authorization = Data(authOrigin.utf8).base64EncodedString()

        // 鉴权：authorization/date/host 作为 URL query 参数（讯飞文档规范）
        var comp = URLComponents()
        comp.scheme = "wss"
        comp.host = host
        comp.path = path
        comp.queryItems = [
            URLQueryItem(name: "authorization", value: authorization),
            URLQueryItem(name: "date", value: dateStr),
            URLQueryItem(name: "host", value: host)
        ]
        guard let url = comp.url else { complete(); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: request)
        webSocket?.resume()

        let business: [String: Any] = [
            "aue": "raw",                        // 原始 PCM，稳定拼接为 WAV 后播放
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
                case .string(let text):
                    self.handleText(text)
                case .data(let data):
                    self.audioData.append(data)
                    self.receiveLoop()
                @unknown default:
                    self.finishPlay()
                }
            case .failure:
                // 连接关闭 = 数据流结束
                self.finishPlay()
            }
        }
    }

    /// 解析响应：data.audio 为 base64 音频，data.status == 2 表示结束
    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            receiveLoop(); return
        }
        if let code = json["code"] as? Int, code != 0 {
            failNoAudio(); return
        }
        let d = json["data"] as? [String: Any]
        if let b64 = d?["audio"] as? String, let bytes = Data(base64Encoded: b64) {
            audioData.append(bytes)
        }
        if let status = d?["status"] as? Int, status == 2 {
            finishPlay()
        } else {
            receiveLoop()
        }
    }

    // MARK: - 播放 & 收尾

    private func finishPlay() {
        guard !audioData.isEmpty else { failNoAudio(); return }
        let wav = Self.wrapWAV(pcm: audioData, sampleRate: 16000)
        do {
            player = try AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue)
            player?.delegate = self
            player?.volume = 1.0
            player?.play()
        } catch {
            complete()
        }
    }

    /// PCM(16bit/16k/mono) 包一层 WAV 头，供 AVAudioPlayer 播放
    static func wrapWAV(pcm: Data, sampleRate: Int) -> Data {
        var wav = Data()
        func str(_ s: String) { wav.append(Data(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        let channels = 1, bits = 16
        let byteRate = sampleRate * channels * bits / 8
        let blockAlign = channels * bits / 8
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bits))
        str("data"); u32(UInt32(pcm.count)); wav.append(pcm)
        return wav
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        webSocket?.cancel(with: .goingAway, reason: nil)
        onFinish?()
    }

    private func failNoAudio() {
        guard !finished else { return }
        finished = true
        webSocket?.cancel(with: .goingAway, reason: nil)
        onNoAudio?()
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
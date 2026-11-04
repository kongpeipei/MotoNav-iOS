import Foundation
import AVFoundation
import CommonCrypto

@MainActor
final class XFTTSClient: ObservableObject {
    @Published var isSpeaking = false
    private let appId: String, apiKey: String, apiSecret: String

    init() {
        let b = Bundle.main.infoDictionary ?? [:]
        self.appId     = (b["XF_APP_ID"]     as? String ?? "").trimmingCharacters(in: .whitespaces)
        self.apiKey    = (b["XF_API_KEY"]    as? String ?? "").trimmingCharacters(in: .whitespaces)
        self.apiSecret = (b["XF_API_SECRET"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    }

    func synthesize(_ text: String, vcn: String = "xiaoyan") {
        guard !appId.isEmpty, !apiKey.isEmpty, !apiSecret.isEmpty else {
            fallbackSpeak(text); return
        }
        guard let url = makeURL() else {
            fallbackSpeak(text); return
        }
        Task { await performWebSocket(url: url, text: text, vcn: vcn) }
    }

    private func makeURL() -> URL? {
        let host = "tts-api.xfyun.cn", uri = "/v2/tts"
        let dateStr = rfc1123GMT()
        let signatureOrigin = "host: \(host)\ndate: \(dateStr)\nGET \(uri) HTTP/1.1"
        guard let sig = hmacSHA256(signatureOrigin, key: apiSecret) else { return nil }
        let authOrigin = "api_key=\"\(apiKey)\",algorithm=\"hmac-sha256\",headers=\"host date request-line\",signature=\"\(sig)\""
        guard let authB64 = Data(authOrigin.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        var c = URLComponents(string: "wss://\(host)/v2/tts")!
        c.queryItems = [
            URLQueryItem(name: "authorization", value: authB64),
            URLQueryItem(name: "date", value: dateStr),
            URLQueryItem(name: "host", value: host)
        ]
        return c.url
    }

    private func performWebSocket(url: URL, text: String, vcn: String) async {
        let frameData = frameJSON(text: text, vcn: vcn, status: 2)
        let ws = URLSession.shared.webSocketTask(with: url)
        ws.resume()
        ws.send(.string(String(data: frameData, encoding: .utf8)!)) { err in
            if err != nil { Task { @MainActor in self.fallbackSpeak(text) } }
        }
    }

    private func frameJSON(text: String, vcn: String, status: Int) -> Data {
        let obj: [String: Any] = [
            "common":   ["app_id": appId],
            "business": ["aue":"lame","auf":"audio/L16;rate=16000","vcn":vcn,"tte":"utf8","speed":50],
            "data":     ["status": status, "text": Data(text.utf8).base64EncodedString()]
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    private func fallbackSpeak(_ text: String) {
        let syn = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.5
        syn.speak(u)
    }
}

private func rfc1123GMT() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return f.string(from: Date())
}

private func hmacSHA256(_ message: String, key: String) -> String? {
    guard let msgData = message.data(using: .utf8), let keyData = key.data(using: .utf8) else { return nil }
    var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), (keyData as NSData).bytes, keyData.count, (msgData as NSData).bytes, msgData.count, &mac)
    return Data(mac).base64EncodedString()
}

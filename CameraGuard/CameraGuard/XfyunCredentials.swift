import Foundation
import CryptoKit

/// v1.13 内置讯飞语音凭证：AES-GCM 加密存储（密钥与密文分离），运行时解密后再注入语音引擎。
/// 说明：本地内置凭证采用固定密钥是 iOS 通行做法，可防止「静态明文提取」；
/// 任何本地加密都可通过逆向还原，请勿将该账号凭证用于公共/多用户分发场景。
enum BuiltinXfyun {
    /// 32 字节密钥（与密文分离存放，均非明文）
    private static let keyData = Data(base64Encoded: "5zu3dS0ByeBwIMpddnuHu/BxTJiBzrqTQOvX/yxsAGc=")!
    /// nonce || ciphertext || tag
    private static let combinedB64 = "UrUERE6+n9Tzm6E6jsultvxVlHMBxYMzNjD+yFdiRyrsVf8WJN4eGWrgVULw/8XkBmC+14u8XJ8xU3jjIGyyQMBm87oLOLIRNhs0iQult9OKt2VfE4/wJ9YWMNwSC0HXn2PtLouh"

    /// 内置默认发音人（讯飞小璇·英文）
    static let defaultVcn = "x4_lingxiaoxuan_en"

    /// 解密内置凭证；失败返回 nil（App 回退系统语音，不影响使用）
    static func decrypt() -> (appid: String, apiKey: String, apiSecret: String)? {
        guard let combined = Data(base64Encoded: combinedB64),
              let box = try? AES.GCM.SealedBox(combined: combined) else { return nil }
        guard let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)) else { return nil }
        let parts = String(decoding: plain, as: UTF8.self).split(separator: "|").map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// 发音人显示名（未知 vcn 回退原值）
    static func vcnDisplayName(_ vcn: String) -> String {
        switch vcn {
        case "x4_lingxiaoxuan_en": return "讯飞小璇(英文)"
        default: return vcn
        }
    }
}

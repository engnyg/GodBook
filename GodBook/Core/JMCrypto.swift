import CommonCrypto
import CryptoKit
import UIKit

/// 禁漫行動端 API 的加解密與圖片還原，移植自 jmcomic (MIT) 的 JmCryptoTool / JmImageTool。
enum JMCrypto {
    /// 簽章密鑰會隨官方 App 版本更換；依序嘗試，記住可用的那一組。
    /// 第一組來自 jmcomic，第二組（舊版）來自 jmcomic-downloader。
    struct Profile {
        let tokenSecret: String
        let scrambleSecret: String
        let version: String
    }
    static let profiles = [
        Profile(tokenSecret: "185Hcomic3PAPP7R", scrambleSecret: "18comicAPPContent", version: "2.1.7"),
        Profile(tokenSecret: "18comicAPP", scrambleSecret: "18comicAPPContent", version: "2.0.13"),
    ]
    static let dataSecret = "185Hcomic3PAPP7R"
    static let domainServerSecret = "diosfjckwpqpdfjkvnqQjsik"

    static let scramble268850 = 268850
    static let scramble421926 = 421926

    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 回傳 (token, tokenparam)
    static func token(ts: String, secret: String, version: String) -> (String, String) {
        (md5Hex(ts + secret), "\(ts),\(version)")
    }

    /// Base64 → AES-256-ECB 解密（金鑰為 md5(ts+secret) 的 32 個 ASCII 字元）→ 去除尾端 padding
    static func decrypt(_ base64: String, ts: String, secret: String) throws -> Data {
        let cleaned = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encrypted = Data(base64Encoded: cleaned) else {
            throw AppError.message(L("回應資料不是有效的 Base64"))
        }
        let key = Array(md5Hex(ts + secret).utf8)
        let capacity = encrypted.count + kCCBlockSizeAES128
        var output = [UInt8](repeating: 0, count: capacity)
        var moved = 0
        let status: CCCryptorStatus = encrypted.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                CCCrypt(CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        key, key.count,
                        nil,
                        input.baseAddress, encrypted.count,
                        out.baseAddress, capacity,
                        &moved)
            }
        }
        guard status == kCCSuccess, moved > 0 else { throw AppError.message(L("解密失敗 (%@)", "\(status)")) }
        let padding = Int(output[moved - 1])
        let end = (1...16).contains(padding) && padding <= moved ? moved - padding : moved
        return Data(output[0..<end])
    }

    /// 圖片切割份數。aid 為章節 id；filename 為不含副檔名的圖片名稱。
    static func scrambleCount(scrambleId: Int, aid: Int, filename: String) -> Int {
        if aid < scrambleId { return 0 }
        if aid < scramble268850 { return 10 }
        let x = aid < scramble421926 ? 10 : 8
        let hash = md5Hex("\(aid)\(filename)")
        guard let last = hash.unicodeScalars.last else { return 0 }
        return Int(last.value) % x * 2 + 2
    }
}

enum Descrambler {
    /// 還原被切成 `num` 條水平帶並上下重排的圖片。
    static func descramble(_ image: UIImage, num: Int) -> UIImage? {
        guard num > 1, let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        let over = h % num
        let step = h / num

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        return renderer.image { _ in
            for i in 0..<num {
                var move = step
                let ySrc = h - step * (i + 1) - over
                var yDst = step * i
                if i == 0 {
                    move += over
                } else {
                    yDst += over
                }
                guard ySrc >= 0, let piece = cg.cropping(to: CGRect(x: 0, y: ySrc, width: w, height: move)) else { continue }
                UIImage(cgImage: piece).draw(in: CGRect(x: 0, y: yDst, width: w, height: move))
            }
        }
    }
}

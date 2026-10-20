import Photos
import UIKit

/// 儲存圖片到相簿：先確認「加入照片」權限，使用者拒絕時回報失敗，而不是假裝已儲存。
enum PhotoSaver {
    static func save(_ image: UIImage) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return true
        } catch {
            return false
        }
    }

    static func resultMessage(_ saved: Bool) -> String {
        saved ? L("已儲存到相簿") : L("無法儲存到相簿，請到 iOS「設定 → GodBook → 照片」允許加入照片")
    }
}

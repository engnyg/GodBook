import SwiftUI
import UIKit

/// venera 縮圖語法：`網址@x=起-迄&y=起-迄`（單位為像素；省略的軸取整張）
enum ThumbnailCrop {
    struct Parsed {
        var base: String
        var x: ClosedRange<CGFloat>?
        var y: ClosedRange<CGFloat>?
        var suffix: String
    }

    static func parse(_ key: String) -> Parsed {
        guard let at = key.range(of: "@", options: .backwards) else { return Parsed(base: key, suffix: "") }
        let tail = key[at.upperBound...]
        guard tail.hasPrefix("x=") || tail.hasPrefix("y=") else { return Parsed(base: key, suffix: "") }
        var parsed = Parsed(base: String(key[..<at.lowerBound]), suffix: String(key[at.lowerBound...]))
        for part in tail.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let range = pair[1].split(separator: "-").compactMap { Double($0) }
            guard range.count == 2, range[1] > range[0] else { continue }
            let closed = CGFloat(range[0])...CGFloat(range[1])
            if pair[0] == "x" { parsed.x = closed } else if pair[0] == "y" { parsed.y = closed }
        }
        return parsed
    }

    static func apply(_ parsed: Parsed, to image: UIImage) -> UIImage {
        guard parsed.x != nil || parsed.y != nil, let cg = image.cgImage else { return image }
        let scale = image.scale
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let x0 = max(0, (parsed.x?.lowerBound ?? 0) * (parsed.x == nil ? 1 : 1))
        let x1 = min(width, parsed.x?.upperBound ?? width)
        let y0 = max(0, parsed.y?.lowerBound ?? 0)
        let y1 = min(height, parsed.y?.upperBound ?? height)
        guard x1 > x0, y1 > y0, let cropped = cg.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else { return image }
        return UIImage(cgImage: cropped, scale: scale, orientation: image.imageOrientation)
    }
}

actor ImageLoader {
    static let shared = ImageLoader()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 256 << 20
        return cache
    }()
    private var inflight: [String: Task<UIImage, Error>] = [:]

    static func cacheKey(_ spec: ImageSpec) -> String {
        if spec.source.isVenera {
            let base = ThumbnailCrop.parse(spec.imageKey ?? spec.url.absoluteString).base
            return "\(spec.source.rawValue)|\(spec.comicId ?? "")|\(spec.epId ?? "")|\(base)"
        }
        var components = URLComponents(url: spec.url, resolvingAgainstBaseURL: false)
        components?.query = nil // 禁漫的 ?v=timestamp 每次不同，不應影響快取
        return "\(components?.string ?? spec.url.absoluteString)#\(spec.scramble)"
    }

    /// 記憶體快取鍵：同一張底圖的不同裁切要分開
    private func key(for spec: ImageSpec) -> String {
        Self.cacheKey(spec) + (spec.source.isVenera ? ThumbnailCrop.parse(spec.imageKey ?? "").suffix : "")
    }

    func clearMemory() { cache.removeAllObjects() }

    func image(for spec: ImageSpec) async throws -> UIImage {
        let key = key(for: spec)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let task = inflight[key] { return try await task.value }

        let task = Task { try await Self.fetch(spec) }
        inflight[key] = task
        defer { inflight[key] = nil }
        let image = try await task.value
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    private static func fetch(_ spec: ImageSpec) async throws -> UIImage {
        let data = try await rawData(spec)
        guard var image = UIImage(data: data) else { throw AppError.message(L("無法解碼圖片")) }
        if spec.source.isVenera, let key = spec.imageKey {
            let parsed = ThumbnailCrop.parse(key)
            if !parsed.suffix.isEmpty { image = ThumbnailCrop.apply(parsed, to: image) }
        }
        if spec.scramble > 1, let restored = Descrambler.descramble(image, num: spec.scramble) {
            image = restored
        }
        // 超大的圖（例如條漫、高解析掃描）解碼成點陣圖要幾十 MB，滾動時會卡頓、也容易吃光記憶體；
        // 縮到寬度 2048 像素以內再解碼（在背景執行緒），一般螢幕與縮放都夠用
        let maxPixelWidth: CGFloat = 2048
        let pixelWidth = image.size.width * image.scale
        if pixelWidth > maxPixelWidth {
            let ratio = maxPixelWidth / pixelWidth
            let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            if let thumbnail = await image.byPreparingThumbnail(ofSize: target) { return thumbnail }
        }
        return await image.byPreparingForDisplay() ?? image
    }

    /// 下載（或讀取本機）原始圖片資料；網路錯誤最多重試 3 次。
    static func rawData(_ spec: ImageSpec) async throws -> Data {
        if spec.url.isFileURL { return try Data(contentsOf: spec.url) }
        let diskKey = cacheKey(spec)
        if let cached = ImageDiskCache.read(diskKey) { return cached }
        let data = try await fetchRemote(spec)
        ImageDiskCache.write(diskKey, data)
        return data
    }

    private static func fetchRemote(_ spec: ImageSpec) async throws -> Data {
        if spec.source.isVenera {
            return try await VeneraRuntime.shared.loadImage(
                sourceKey: spec.source.veneraKey,
                imageKey: ThumbnailCrop.parse(spec.imageKey ?? spec.url.absoluteString).base,
                comicId: spec.comicId, epId: spec.epId)
        }

        var lastError: Error = AppError.message(L("下載圖片失敗"))
        for attempt in 0..<3 {
            do {
                var result = try await HTTP.data(for: makeRequest(spec, url: spec.url))
                if result.1.statusCode == 200, result.0.isEmpty, spec.source == .jmcomic {
                    // 禁漫 CDN 偶爾回傳空內容（快取失效）；加上時間戳再要一次
                    result = try await HTTP.data(for: makeRequest(spec, url: cacheBusted(spec.url)))
                }
                guard result.1.statusCode == 200, !result.0.isEmpty else {
                    throw AppError.http(result.1.statusCode)
                }
                return result.0
            } catch {
                lastError = error
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if case AppError.http(let code) = error, code == 403 || code == 404 { break }
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 600_000_000)
            }
        }
        throw lastError
    }

    /// 供下載使用：回傳可直接存檔的資料與副檔名。禁漫被切割的圖片會先還原並存成 JPEG。
    static func downloadData(_ spec: ImageSpec) async throws -> (Data, String) {
        let data = try await rawData(spec)
        if spec.scramble > 1,
           let image = UIImage(data: data),
           let restored = Descrambler.descramble(image, num: spec.scramble),
           let jpeg = restored.jpegData(compressionQuality: 0.92) {
            return (jpeg, "jpg")
        }
        return (data, sniffExtension(data, fallback: spec.url.pathExtension))
    }

    private static func makeRequest(_ spec: ImageSpec, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if spec.source == .jmcomic {
            request.setValue(JMClient.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("com.JMComic3.app", forHTTPHeaderField: "X-Requested-With")
            request.setValue("https://www.cdnhjk.net", forHTTPHeaderField: "Referer")
        } else {
            request.setValue("NClient/3 (GodBook iOS)", forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    private static func cacheBusted(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "v" && $0.name != "ts" }
        items.append(URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970))))
        components.queryItems = items
        return components.url ?? url
    }

    static func sniffExtension(_ data: Data, fallback: String) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return fallback.isEmpty ? "jpg" : fallback.lowercased()
    }
}

/// 非同步載入遠端圖片（支援禁漫還原與請求標頭）。
struct RemoteImageView: View {
    let spec: ImageSpec?
    var fill = false
    /// 載入前的預留高寬比 (寬/高)
    var placeholderAspect: CGFloat = 0.72

    @State private var image: UIImage?
    @State private var loadedSpec: ImageSpec?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        ZStack {
            if let image {
                if fill {
                    // 用透明底色決定尺寸、圖片只當內容裁切；否則橫幅等寬圖會把版面撐出螢幕
                    Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }.clipped()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                Color.gray.opacity(0.14)
                    .aspectRatio(placeholderAspect, contentMode: .fit)
                    .overlay {
                        if failed {
                            Button {
                                failed = false
                                attempt += 1
                            } label: {
                                Image(systemName: "arrow.clockwise").font(.title3)
                            }
                            .buttonStyle(.plain)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .task(id: TaskKey(spec: spec, attempt: attempt)) { await load() }
    }

    private struct TaskKey: Hashable {
        var spec: ImageSpec?
        var attempt: Int
    }

    private func load() async {
        guard let spec else { return }
        if loadedSpec == spec, image != nil { return }
        image = nil
        failed = false // 換了圖片（例如列表重用）時，不要沿用上一張的失敗狀態
        do {
            let loaded = try await ImageLoader.shared.image(for: spec)
            image = loaded
            loadedSpec = spec
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

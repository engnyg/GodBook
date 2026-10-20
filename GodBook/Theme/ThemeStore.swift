import SwiftUI
import UIKit

enum BackgroundMode: String, Codable, CaseIterable, Identifiable {
    case system, solid, gradient, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L("系統")
        case .solid: L("純色")
        case .gradient: L("漸層")
        case .image: L("圖片")
        }
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L("跟隨系統")
        case .light: L("淺色")
        case .dark: L("深色")
        }
    }
}

struct ThemeConfig: Codable, Equatable {
    var accentHex = "#FF5A7A"
    var backgroundMode = BackgroundMode.gradient
    var solidHex = "#14141F"
    var gradientStartHex = "#5B3DF5"
    var gradientEndHex = "#FF5A7A"
    var imageBlur: Double = 0
    var imageDim: Double = 0.25
    var useGlass = true
    var glassTint: Double = 0.18
    var appearance = AppearanceMode.system
}

/// 主題設定：強調色、背景（系統 / 純色 / 漸層 / 自選圖片）與液態玻璃參數。
final class ThemeStore: ObservableObject {
    private static let defaultsKey = "theme.config.v1"

    @Published var config: ThemeConfig {
        didSet { persist() }
    }
    @Published private(set) var backgroundImage: UIImage?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(ThemeConfig.self, from: data) {
            config = decoded
        } else {
            config = ThemeConfig()
        }
        backgroundImage = UIImage(contentsOfFile: Self.imageURL.path)
    }

    var accent: Color { Color(hex: config.accentHex) }

    var preferredScheme: ColorScheme? {
        switch config.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func colorBinding(_ keyPath: WritableKeyPath<ThemeConfig, String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: self.config[keyPath: keyPath]) },
            set: { self.config[keyPath: keyPath] = $0.hexString }
        )
    }

    func reset() {
        config = ThemeConfig()
        clearBackgroundImage()
    }

    // MARK: - 背景圖片

    private static var imageURL: URL {
        Storage.directory.appendingPathComponent("background.jpg")
    }

    func setBackgroundImage(data: Data) {
        guard let source = UIImage(data: data) else { return }
        let image = source.downscaled(maxSide: 2200)
        if let jpeg = image.jpegData(compressionQuality: 0.88) {
            try? jpeg.write(to: Self.imageURL, options: .atomic)
        }
        backgroundImage = image
        config.backgroundMode = .image
    }

    func clearBackgroundImage() {
        try? FileManager.default.removeItem(at: Self.imageURL)
        backgroundImage = nil
        if config.backgroundMode == .image { config.backgroundMode = .gradient }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - 預設配色

struct ThemePreset: Identifiable {
    let id = UUID()
    let name: String
    let accent: String
    let start: String
    let end: String
}

extension ThemePreset {
    static let all: [ThemePreset] = [
        .init(name: L("櫻花"), accent: "#FF5A7A", start: "#5B3DF5", end: "#FF5A7A"),
        .init(name: L("極光"), accent: "#30D5A0", start: "#0F2027", end: "#2C9F8B"),
        .init(name: L("夕陽"), accent: "#FF9F0A", start: "#FF512F", end: "#F09819"),
        .init(name: L("深海"), accent: "#0A84FF", start: "#0F2A5C", end: "#1B9CE0"),
        .init(name: L("葡萄"), accent: "#BF5AF2", start: "#2B1055", end: "#7597DE"),
        .init(name: L("石墨"), accent: "#8E8E93", start: "#1C1C1E", end: "#3A3A3C"),
    ]
}

// MARK: - 工具

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        if s.count == 6 { s += "FF" }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 24) & 0xFF) / 255,
            green: Double((value >> 16) & 0xFF) / 255,
            blue: Double((value >> 8) & 0xFF) / 255,
            opacity: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()),
                      Int((b * 255).rounded()), Int((a * 255).rounded()))
    }
}

extension UIImage {
    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

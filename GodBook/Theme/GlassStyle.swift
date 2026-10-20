import SwiftUI

// MARK: - 背景

struct ThemeBackground: View {
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch theme.config.backgroundMode {
                case .system:
                    Color(.systemGroupedBackground)
                case .solid:
                    Color(hex: theme.config.solidHex)
                case .gradient:
                    LinearGradient(
                        colors: [Color(hex: theme.config.gradientStartHex), Color(hex: theme.config.gradientEndHex)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                case .image:
                    if let image = theme.backgroundImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .blur(radius: theme.config.imageBlur)
                            .overlay(Color.black.opacity(theme.config.imageDim))
                    } else {
                        Color(.systemGroupedBackground)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

private struct ThemedScreen: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { ThemeBackground() }
    }
}

extension View {
    /// 讓畫面套用使用者自訂的背景。
    func themedScreen() -> some View { modifier(ThemedScreen()) }
}

// MARK: - 液態玻璃

private struct GlassModifier<S: Shape>: ViewModifier {
    @EnvironmentObject private var theme: ThemeStore
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if theme.config.useGlass {
            glassed(content)
        } else {
            content.background(Color(.secondarySystemBackground).opacity(0.92), in: shape)
        }
    }

    @ViewBuilder
    private func glassed(_ content: Content) -> some View {
        let tintColor = tint ?? theme.accent.opacity(theme.config.glassTint)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tintColor).interactive(interactive), in: shape)
        } else {
            materialFallback(content, tintColor)
        }
        #else
        materialFallback(content, tintColor)
        #endif
    }

    /// iOS 17–25：用模糊材質 + 高光描邊模擬玻璃。
    private func materialFallback(_ content: Content, _ tintColor: Color) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .background(tintColor, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.6))
    }
}

extension View {
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassModifier(shape: shape, tint: tint, interactive: interactive))
    }

    func glassCard(cornerRadius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        glass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint, interactive: interactive)
    }

    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        glass(in: Capsule(), tint: tint, interactive: interactive)
    }
}

/// 玻璃按鈕。`prominent` 會帶入較濃的強調色。
struct GlassButton: View {
    @EnvironmentObject private var theme: ThemeStore
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: 22,
                   tint: prominent ? theme.accent.opacity(0.65) : nil,
                   interactive: true)
    }
}

/// 設定頁常用的玻璃面板（標題 + 內容）
struct GlassPanel<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 26)
    }
}

// MARK: - 標籤流式排版

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

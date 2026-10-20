import SwiftUI

/// 連續捲動閱讀器（由上到下 / 左到右 / 右到左），支援捏合與雙擊縮放。
struct ContinuousReader: View {
    let pages: [ReaderPage]
    @Binding var current: Int
    let horizontal: Bool
    let rtl: Bool
    let prefs: ReaderPrefs
    let onTap: (CGPoint) -> Void
    let onQuickCollect: (Int) -> Void
    /// 下一章標題；為 nil 表示不顯示章節盡頭的過場區
    var nextTitle: String?
    var onNext: () -> Void = {}

    @State private var edgeVisible = false
    @State private var scrollID: Int?
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var size: CGSize = .zero
    @State private var didStart = false

    private var ordered: [ReaderPage] { rtl ? Array(pages.reversed()) : pages }

    var body: some View {
        GeometryReader { geo in
            ScrollView(zoom > 1.01 ? [.vertical, .horizontal] : (horizontal ? .horizontal : .vertical)) {
                if horizontal {
                    LazyHStack(spacing: 0) { items(geo.size) }.scrollTargetLayout()
                } else {
                    LazyVStack(spacing: 0) { items(geo.size) }.scrollTargetLayout()
                }
            }
            .scrollPosition(id: $scrollID, anchor: horizontal ? .leading : .top)
            .scrollIndicators(.hidden)
            .gesture(tapGesture(geo.size))
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { zoom = min(max(zoomBase * $0.magnification, 1), 4) }
                    .onEnded { _ in zoomBase = zoom }
            )
            .onAppear { size = geo.size }
        }
        .onChange(of: scrollID) { _, id in
            if let id, id < pages.count, id != current { current = id }
        }
        .onChange(of: current) { _, value in
            if scrollID != value { withAnimation(prefs.pageAnimation ? .easeInOut(duration: 0.25) : nil) { scrollID = value } }
        }
        .task {
            guard !didStart else { return }
            didStart = true
            try? await Task.sleep(nanoseconds: 120_000_000)
            scrollID = current
        }
    }

    @ViewBuilder
    private func items(_ container: CGSize) -> some View {
        if rtl { edgeItem(container) }
        ForEach(ordered) { page in
            RemoteImageView(spec: page.image, loadDelay: 0.12)
                .frame(width: horizontal ? nil : container.width * zoom,
                       height: horizontal ? container.height * zoom : nil)
                .id(page.index)
        }
        if !rtl { edgeItem(container) }
    }

    /// 章節盡頭的過場區：露出後稍等一下就自動進入下一章
    @ViewBuilder
    private func edgeItem(_ container: CGSize) -> some View {
        if let nextTitle {
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(L("下一章") + "\n" + nextTitle)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(24)
            .frame(width: horizontal ? container.width : container.width,
                   height: horizontal ? container.height : 220)
            .onAppear {
                edgeVisible = true
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if edgeVisible, didStart, current >= pages.count - 1 { onNext() }
                }
            }
            .onDisappear { edgeVisible = false }
        }
    }

    private func tapGesture(_ container: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { _ in
                if prefs.quickCollect {
                    onQuickCollect(current)
                } else if prefs.doubleTapZoom {
                    withAnimation(.snappy) {
                        zoom = zoom > 1.01 ? 1 : 2
                        zoomBase = zoom
                    }
                }
            }
            .exclusively(before: SpatialTapGesture().onEnded { value in
                onTap(CGPoint(x: value.location.x / max(container.width, 1),
                              y: value.location.y / max(container.height, 1)))
            })
    }
}

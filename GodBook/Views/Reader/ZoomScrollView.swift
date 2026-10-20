import SwiftUI
import UIKit

/// 可縮放的單張圖片（雙擊 / 長按 / 捏合縮放）。分頁閱讀器的每一頁都是它。
final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let retryLabel = UILabel()

    var onSingleTap: ((CGPoint) -> Void)?
    var onQuickCollect: (() -> Void)?
    var doubleTapZoom = true { didSet { updateGestures() } }
    var longPressZoom = true { didSet { updateGestures() } }
    var quickCollect = false { didSet { updateGestures() } }

    private var spec: ImageSpec?
    private var loadTask: Task<Void, Never>?
    private var failed = false
    private let singleTap = UITapGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private let longPress = UILongPressGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        backgroundColor = .black

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        addSubview(spinner)

        retryLabel.text = L("載入失敗，點一下重試")
        retryLabel.textColor = .white
        retryLabel.font = .preferredFont(forTextStyle: .footnote)
        retryLabel.isHidden = true
        addSubview(retryLabel)

        singleTap.addTarget(self, action: #selector(handleSingleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
        singleTap.require(toFail: doubleTap)
        longPress.minimumPressDuration = 0.35
        longPress.addTarget(self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(longPress)
        updateGestures()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateGestures() {
        doubleTap.isEnabled = doubleTapZoom || quickCollect
        longPress.isEnabled = longPressZoom
    }

    // MARK: 版面

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= 1.0001 {
            imageView.frame = bounds
        } else {
            centerContent()
        }
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        retryLabel.sizeToFit()
        retryLabel.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    private func centerContent() {
        let offsetX = max((bounds.width - contentSize.width) / 2, 0)
        let offsetY = max((bounds.height - contentSize.height) / 2, 0)
        imageView.center = CGPoint(x: contentSize.width / 2 + offsetX, y: contentSize.height / 2 + offsetY)
    }

    // MARK: 手勢

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        if failed {
            reload()
            return
        }
        let point = gesture.location(in: self)
        let normalized = CGPoint(x: (point.x - contentOffset.x) / max(bounds.width, 1),
                                 y: (point.y - contentOffset.y) / max(bounds.height, 1))
        onSingleTap?(normalized)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if quickCollect {
            onQuickCollect?()
            return
        }
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            zoom(to: zoomRect(scale: 2.5, center: gesture.location(in: imageView)), animated: true)
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            zoom(to: zoomRect(scale: 2.5, center: gesture.location(in: imageView)), animated: true)
        case .ended, .cancelled, .failed:
            setZoomScale(1, animated: true)
        default:
            break
        }
    }

    private func zoomRect(scale: CGFloat, center: CGPoint) -> CGRect {
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: 載入

    func load(_ newSpec: ImageSpec) {
        if spec == newSpec, imageView.image != nil { return }
        spec = newSpec
        setZoomScale(1, animated: false)
        imageView.image = nil
        reload()
    }

    private func reload() {
        guard let spec else { return }
        failed = false
        retryLabel.isHidden = true
        spinner.startAnimating()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                let image = try await ImageLoader.shared.image(for: spec)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.imageView.alpha = 0
                    self.imageView.image = image
                    self.spinner.stopAnimating()
                    UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) { self.imageView.alpha = 1 }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.spinner.stopAnimating()
                    self?.failed = true
                    self?.retryLabel.isHidden = false
                    self?.setNeedsLayout()
                }
            }
        }
    }

    deinit { loadTask?.cancel() }
}

/// 單獨使用的可縮放圖片（例如圖片收藏的全螢幕檢視）。
struct ZoomableImage: UIViewRepresentable {
    let spec: ImageSpec
    var onTap: (() -> Void)?

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.onSingleTap = { _ in onTap?() }
        view.load(spec)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onSingleTap = { _ in onTap?() }
        view.load(spec)
    }
}

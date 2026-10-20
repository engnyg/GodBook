import SwiftUI
import UIKit

final class ZoomPageViewController: UIViewController {
    let index: Int
    private let spec: ImageSpec
    private var prefs: ReaderPrefs
    var onTap: ((CGPoint) -> Void)?
    var onQuickCollect: ((Int) -> Void)?
    private let scroll = ZoomScrollView()

    init(index: Int, spec: ImageSpec, prefs: ReaderPrefs) {
        self.index = index
        self.spec = spec
        self.prefs = prefs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = scroll
        apply(prefs)
        scroll.onSingleTap = { [weak self] point in self?.onTap?(point) }
        scroll.onQuickCollect = { [weak self] in
            guard let self else { return }
            self.onQuickCollect?(self.index)
        }
        scroll.load(spec)
    }

    func apply(_ newPrefs: ReaderPrefs) {
        prefs = newPrefs
        scroll.doubleTapZoom = newPrefs.doubleTapZoom
        scroll.longPressZoom = newPrefs.longPressZoom
        scroll.quickCollect = newPrefs.quickCollect
    }
}

/// 章節交界的過場頁：滑到這頁就會自動切換到上一章 / 下一章。
final class EdgePageViewController: UIViewController {
    let edge: Int // +1：本章最後一頁之後（下一章）；-1：第一頁之前（上一章）
    private let text: String

    init(edge: Int, text: String) {
        self.edge = edge
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let label = UILabel()
        label.text = text
        label.textColor = UIColor(white: 1, alpha: 0.75)
        label.font = .preferredFont(forTextStyle: .callout)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }
}

/// 分頁閱讀器（左到右 / 右到左 / 上到下），以 UIPageViewController 實作，每頁可縮放。
struct PagedReader: UIViewControllerRepresentable {
    let pages: [ReaderPage]
    @Binding var current: Int
    let vertical: Bool
    let rtl: Bool
    let prefs: ReaderPrefs
    let onTap: (CGPoint) -> Void
    let onQuickCollect: (Int) -> Void
    /// 下一章 / 上一章的標題；為 nil 表示不顯示過場頁（沒有該章，或關閉了自動切章）
    var nextTitle: String?
    var prevTitle: String?
    var onEdge: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: vertical ? .vertical : .horizontal,
            options: [.interPageSpacing: 12])
        controller.view.backgroundColor = .black
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.parent = self
        context.coordinator.show(current, animated: false, in: controller)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        controller.viewControllers?.forEach { ($0 as? ZoomPageViewController)?.apply(prefs) }
        context.coordinator.syncIfNeeded(controller)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PagedReader
        private var displayed = -1

        init(_ parent: PagedReader) { self.parent = parent }

        private func makeController(for index: Int) -> UIViewController? {
            if index == parent.pages.count, let title = parent.nextTitle {
                return EdgePageViewController(edge: 1, text: L("下一章") + "\n" + title)
            }
            if index == -1, let title = parent.prevTitle {
                return EdgePageViewController(edge: -1, text: L("上一章") + "\n" + title)
            }
            guard parent.pages.indices.contains(index) else { return nil }
            let controller = ZoomPageViewController(index: index, spec: parent.pages[index].image, prefs: parent.prefs)
            controller.onTap = { [weak self] point in self?.parent.onTap(point) }
            controller.onQuickCollect = { [weak self] page in self?.parent.onQuickCollect(page) }
            return controller
        }

        func show(_ index: Int, animated: Bool, in controller: UIPageViewController) {
            let target = min(max(index, 0), max(parent.pages.count - 1, 0))
            guard let page = makeController(for: target) else { return }
            let forward = displayed < 0 ? true : (parent.rtl ? target < displayed : target > displayed)
            controller.setViewControllers([page], direction: forward ? .forward : .reverse, animated: animated)
            displayed = target
        }

        private func position(of controller: UIViewController) -> Int? {
            if let page = controller as? ZoomPageViewController { return page.index }
            if let edge = controller as? EdgePageViewController { return edge.edge > 0 ? parent.pages.count : -1 }
            return nil
        }

        func syncIfNeeded(_ controller: UIPageViewController) {
            guard displayed != parent.current else { return }
            show(parent.current, animated: parent.prefs.pageAnimation, in: controller)
        }

        // MARK: DataSource（RTL 時前後對調）

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let position = position(of: viewController) else { return nil }
            return makeController(for: parent.rtl ? position + 1 : position - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let position = position(of: viewController) else { return nil }
            return makeController(for: parent.rtl ? position - 1 : position + 1)
        }

        // MARK: Delegate

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let shown = pageViewController.viewControllers?.first else { return }
            if let edge = shown as? EdgePageViewController {
                displayed = parent.current // 停在過場頁，不要被同步邏輯拉回最後一頁
                let delta = edge.edge
                DispatchQueue.main.async { self.parent.onEdge(delta) }
                return
            }
            guard let page = shown as? ZoomPageViewController else { return }
            displayed = page.index
            DispatchQueue.main.async { self.parent.current = page.index }
        }
    }
}

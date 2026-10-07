import Combine
import SwiftUI
import UIKit

/// Hosts a page-curl `UIPageViewController`: one page in portrait, a
/// two-page spread (cover on its own, like a printed book) in landscape.
final class BookReaderViewController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private let session: BookSession
    private var pageController: UIPageViewController?
    private var isSpread = false
    private var isTransitioning = false
    private var pendingFocus: FocusRequest?
    private var cancellables = Set<AnyCancellable>()
    private let turnFeedback = UIImpactFeedbackGenerator(style: .light)

    init(session: BookSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Slots
    //
    // A "slot" is a position in the page-curl sequence. In two-page view slot 0
    // is the blank inside of the front cover, so page 0 (the cover) sits alone
    // on the right and every later spread shows an even/odd pair like a book.

    private var coverOffset: Int { isSpread ? 1 : 0 }

    private var slotCount: Int {
        let count = session.pageCount + coverOffset
        return isSpread ? count + count % 2 : count
    }

    private func pageIndex(forSlot slot: Int) -> Int? {
        let page = slot - coverOffset
        return (0..<session.pageCount).contains(page) ? page : nil
    }

    private func slot(forPage page: Int) -> Int { page + coverOffset }

    private var visibleSheets: [PageViewController] {
        (pageController?.viewControllers ?? []).compactMap { $0 as? PageViewController }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Paper.desk

        session.$pageFocus
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in self?.handle(request) }
            .store(in: &cancellables)

        session.$tool.map(\.kind).removeDuplicates()
            .combineLatest(session.$fingerDrawing.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateCurlGestures() }
            .store(in: &cancellables)

        session.$twoPageSpread.removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.view.setNeedsLayout() }
            .store(in: &cancellables)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let wantsSpread = session.twoPageSpread && bounds.width > bounds.height && bounds.width >= 700
        if pageController == nil || wantsSpread != isSpread {
            rebuild(spread: wantsSpread, page: visibleSheets.compactMap(\.pageIndex).first ?? session.currentPage)
        }
    }

    private func rebuild(spread: Bool, page: Int) {
        if let old = pageController {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        isSpread = spread
        isTransitioning = false

        let spine: UIPageViewController.SpineLocation = spread ? .mid : .min
        let controller = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: NSNumber(value: spine.rawValue)]
        )
        controller.isDoubleSided = spread
        controller.dataSource = self
        controller.delegate = self
        controller.view.backgroundColor = .clear

        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        pageController = controller

        controller.setViewControllers(sheets(showing: page), direction: .forward, animated: false)
        updateCurlGestures()
        didShowPages()

        if let request = pendingFocus {
            pendingFocus = nil
            handle(request)
        }
    }

    // MARK: - Sheets

    private func sheets(showing page: Int) -> [UIViewController] {
        if isSpread {
            let pageSlot = slot(forPage: page)
            let left = pageSlot - pageSlot % 2
            return [makeSheet(slot: left), makeSheet(slot: left + 1)]
        }
        return [makeSheet(slot: page)]
    }

    private func makeSheet(slot: Int) -> PageViewController {
        let side: SheetSide = isSpread ? (slot % 2 == 0 ? .left : .right) : .single
        let sheet = PageViewController(session: session, slot: slot, pageIndex: pageIndex(forSlot: slot), side: side)
        sheet.onZoomStateChange = { [weak self] _ in self?.updateCurlGestures() }
        return sheet
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let sheet = viewController as? PageViewController, sheet.slot > 0 else { return nil }
        return makeSheet(slot: sheet.slot - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let sheet = viewController as? PageViewController, sheet.slot + 1 < slotCount else { return nil }
        return makeSheet(slot: sheet.slot + 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        isTransitioning = true
        turnFeedback.prepare()
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        isTransitioning = false
        guard completed else { return }
        if session.pageTurnHaptics { turnFeedback.impactOccurred(intensity: 0.6) }
        didShowPages()
    }

    private func didShowPages() {
        let pages = visibleSheets.compactMap(\.pageIndex)
        if !pages.isEmpty { session.readerDidShow(pages: pages) }
        updateCurlGestures()
        prefetchNeighbours(of: pages)
    }

    /// Renders the next and previous pages ahead of time so the curl always shows ink-ready paper.
    private func prefetchNeighbours(of pages: [Int]) {
        guard let first = pages.first, let last = pages.last, let controller = pageController else { return }
        let sheetBounds: CGRect = isSpread
            ? CGRect(x: 0, y: 0, width: controller.view.bounds.width / 2, height: controller.view.bounds.height)
            : controller.view.bounds
        let scale = view.traitCollection.displayScale
        let span = isSpread ? 4 : 2
        let candidates = Array((last + 1)...(last + span)) + Array((first - span)..<first).reversed()
        for page in candidates where (0..<session.pageCount).contains(page) {
            let side: SheetSide = isSpread ? (slot(forPage: page) % 2 == 0 ? .left : .right) : .single
            let frame = PageViewController.pageFrame(for: session.renderer.geometry(page), in: sheetBounds, side: side)
            guard frame.width > 0 else { continue }
            session.renderer.prefetch(pages: [page], width: frame.width, scale: scale)
        }
    }

    // MARK: - Gestures

    /// Page turning is for fingers (and Apple Pencil in Read mode). It's switched
    /// off while a tool needs single-finger drags, while finger drawing is on,
    /// and while a page is zoomed in (so one finger can move around the page).
    private func updateCurlGestures() {
        guard let controller = pageController else { return }
        let kind = session.tool.kind
        let blocked = kind.capturesTouches
            || (session.fingerDrawing && kind.isInkTool)
            || visibleSheets.contains(where: \.isZoomed)
        var touchTypes = [UITouch.TouchType.direct, .indirectPointer]
        if kind == .read { touchTypes.append(.pencil) }
        for recognizer in controller.gestureRecognizers {
            recognizer.isEnabled = !blocked
            recognizer.allowedTouchTypes = touchTypes.map { NSNumber(value: $0.rawValue) }
            (recognizer as? UIPanGestureRecognizer)?.maximumNumberOfTouches = 1
        }
    }

    // MARK: - Navigation

    private func handle(_ request: FocusRequest) {
        // Consume the request so it isn't replayed if the reader is rebuilt.
        if session.pageFocus?.id == request.id { session.pageFocus = nil }
        guard case .page(let page) = request.surface else { return }
        guard let controller = pageController else {
            pendingFocus = request  // handled once the first layout builds the pages
            return
        }

        let visible = visibleSheets.compactMap(\.pageIndex)
        if visible.contains(page) {
            if let rect = request.rect { flash(rect, onPage: page, after: 0) }
            return
        }

        let currentSlot = visibleSheets.first?.slot ?? 0
        let targetSlot = slot(forPage: page)
        let direction: UIPageViewController.NavigationDirection = targetSlot > currentSlot ? .forward : .reverse
        let isNeighbour = abs(targetSlot - currentSlot) <= (isSpread ? 2 : 1)
        let targetSheets = sheets(showing: page)

        if isNeighbour && request.animated && !isTransitioning {
            isTransitioning = true
            controller.setViewControllers(targetSheets, direction: direction, animated: true) { [weak self] _ in
                self?.isTransitioning = false
                self?.didShowPages()
            }
            if session.pageTurnHaptics { turnFeedback.impactOccurred(intensity: 0.6) }
            if let rect = request.rect { flash(rect, onPage: page, after: 0.6) }
        } else {
            UIView.transition(with: controller.view, duration: request.animated ? 0.25 : 0, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                controller.setViewControllers(targetSheets, direction: direction, animated: false)
            }
            didShowPages()
            if let rect = request.rect { flash(rect, onPage: page, after: 0.3) }
        }
    }

    private func flash(_ rect: CGRect, onPage page: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.visibleSheets.first { $0.pageIndex == page }?.flash(rect)
        }
    }
}

struct BookReaderView: UIViewControllerRepresentable {
    let session: BookSession

    func makeUIViewController(context: Context) -> BookReaderViewController {
        BookReaderViewController(session: session)
    }

    func updateUIViewController(_ uiViewController: BookReaderViewController, context: Context) {}
}

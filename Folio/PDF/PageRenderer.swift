import PDFKit
import PencilKit
import UIKit

/// Thread-safe page rendering for one book. Uses Core Graphics' PDF parser
/// (safe to draw from background threads) rather than PDFKit, and caches
/// page images so pages are ready before they curl into view.
final class PageRenderer {
    let geometries: [PageGeometry]
    private let document: CGPDFDocument?
    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "folio.page-render", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var inFlight = Set<String>()

    init(url: URL, pdf: PDFDocument) {
        document = CGPDFDocument(url as CFURL)
        geometries = (0..<pdf.pageCount).map { index in
            pdf.page(at: index).map(PageGeometry.init(page:)) ?? PageGeometry(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)
        }
        cache.countLimit = 24
    }

    var pageCount: Int { geometries.count }

    func geometry(_ index: Int) -> PageGeometry {
        geometries.indices.contains(index) ? geometries[index] : PageGeometry(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)
    }

    /// Draws page `index` into a context set up in page space (y down).
    func drawPage(_ index: Int, in context: CGContext) {
        let geometry = geometry(index)
        context.saveGState()
        context.setFillColor(UIColor.white.cgColor)
        context.fill(geometry.bounds)
        if let page = document?.page(at: index + 1) {
            geometry.applyPDFTransform(to: context)
            context.interpolationQuality = .high
            context.setRenderingIntent(.defaultIntent)
            context.drawPDFPage(page)
        }
        context.restoreGState()
    }

    // MARK: Page images

    private func key(_ index: Int, _ pixelWidth: Int) -> String { "\(index)@\(pixelWidth)" }

    func cachedImage(page index: Int, width: CGFloat, scale: CGFloat) -> UIImage? {
        cache.object(forKey: key(index, Int(width * scale)) as NSString)
    }

    /// Renders (or returns the cached) image of a page `width` points wide.
    func image(page index: Int, width: CGFloat, scale: CGFloat) -> UIImage {
        let cacheKey = key(index, Int(width * scale))
        if let cached = cache.object(forKey: cacheKey as NSString) { return cached }
        let geometry = geometry(index)
        let factor = width / max(geometry.size.width, 1)
        let size = CGSize(width: width, height: geometry.size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.scaleBy(x: factor, y: factor)
            drawPage(index, in: ctx.cgContext)
        }
        cache.setObject(image, forKey: cacheKey as NSString)
        return image
    }

    /// Renders upcoming pages in the background so the page curl never shows a blank sheet.
    func prefetch(pages: [Int], width: CGFloat, scale: CGFloat) {
        for index in pages where geometries.indices.contains(index) {
            let cacheKey = key(index, Int(width * scale))
            lock.lock()
            let skip = inFlight.contains(cacheKey) || cache.object(forKey: cacheKey as NSString) != nil
            if !skip { inFlight.insert(cacheKey) }
            lock.unlock()
            if skip { continue }
            queue.async { [weak self] in
                _ = self?.image(page: index, width: width, scale: scale)
                self?.lock.lock()
                self?.inFlight.remove(cacheKey)
                self?.lock.unlock()
            }
        }
    }

    // MARK: Snapshots

    /// Picture of a region of a page with its highlights and ink, used for pin thumbnails.
    func snapshot(page index: Int, region: CGRect, drawing: PKDrawing, highlights: [Highlight], maxPixels: CGFloat) -> UIImage {
        Self.compose(region: region, maxPixels: maxPixels, drawing: drawing, highlights: highlights) { context in
            self.drawPage(index, in: context)
        }
    }

    /// Draws `background`, highlights and ink for `region` into a bitmap.
    /// Safe to call from a background queue.
    static func compose(region: CGRect, maxPixels: CGFloat, drawing: PKDrawing, highlights: [Highlight],
                        background: (CGContext) -> Void) -> UIImage {
        let region = region.integral
        let longest = max(region.width, region.height, 1)
        let scale = min(3, max(0.25, maxPixels / longest))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: region.size, format: format).image { ctx in
            let context = ctx.cgContext
            context.translateBy(x: -region.minX, y: -region.minY)
            background(context)
            HighlightPainter.paint(highlights, in: context)
            var ink: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = drawing.image(from: region, scale: scale)
            }
            ink?.draw(in: region)
        }
    }
}

enum HighlightPainter {
    static let alpha: CGFloat = 0.38

    static func paint(_ highlights: [Highlight], in context: CGContext) {
        for highlight in highlights {
            context.setFillColor(highlight.color.uiColor.withAlphaComponent(alpha).cgColor)
            for rect in highlight.rects {
                context.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -0.5), cornerRadius: 2).cgPath)
            }
            context.fillPath()
        }
    }
}

/// A view backed by `CATiledLayer`: it re-renders sharply at every zoom
/// level and draws tiles on background threads. `renderer` must be thread-safe.
final class TiledLayerView: UIView {
    override class var layerClass: AnyClass { NoFadeTiledLayer.self }

    private let renderer: (CGContext) -> Void

    init(size: CGSize, renderer: @escaping (CGContext) -> Void) {
        self.renderer = renderer
        super.init(frame: CGRect(origin: .zero, size: size))
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        let tiled = layer as! CATiledLayer
        tiled.levelsOfDetail = 4
        tiled.levelsOfDetailBias = 3
        tiled.tileSize = CGSize(width: 512, height: 512)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // An empty draw(_:) tells UIKit to give the layer a backing store; the
    // real drawing happens in draw(_:in:), which CATiledLayer calls per tile.
    override func draw(_ rect: CGRect) {}

    override func draw(_ layer: CALayer, in ctx: CGContext) {
        renderer(ctx)
    }
}

/// CATiledLayer's default tile fade-in looks like flicker on top of the
/// cached page image that sits underneath it.
final class NoFadeTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

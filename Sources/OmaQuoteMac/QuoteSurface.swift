import AppKit
import CoreGraphics
import OmaQuoteCore

struct PresentationConfiguration: Decodable {
    let visible: Bool
    let horizontalAlignment: String
    let verticalPositionRatio: Double
    let maximumWidthRatio: Double
    let maximumHeightRatio: Double
    let screenMargin: Int
    let fontFamily: String?
    let preferredFontSize: Int
    let minimumFontSize: Int
    let textColor: String?
    let attributionColor: String?
    let backdropColor: String?
    let backdropOpacity: Double
    let shadow: Bool

    var quoteColor: NSColor { NSColor(hex: textColor ?? "#cacccc") }
    var authorColor: NSColor { NSColor(hex: attributionColor ?? "#707880") }
    var cardColor: NSColor {
        let color = NSColor(hex: backdropColor ?? "#101315").usingColorSpace(.deviceRGB) ?? .black
        return color.withAlphaComponent(backdropOpacity)
    }
    var fontName: String { fontFamily ?? "Menlo" }
}

private extension NSColor {
    convenience init(hex: String) {
        let digits = String(hex.dropFirst())
        let number = UInt64(digits, radix: 16) ?? 0
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if digits.count == 8 {
            alpha = CGFloat((number >> 24) & 0xff) / 255
            red = CGFloat((number >> 16) & 0xff) / 255
            green = CGFloat((number >> 8) & 0xff) / 255
            blue = CGFloat(number & 0xff) / 255
        } else {
            alpha = 1
            red = CGFloat((number >> 16) & 0xff) / 255
            green = CGFloat((number >> 8) & 0xff) / 255
            blue = CGFloat(number & 0xff) / 255
        }
        self.init(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }
}

private final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuoteSurfaceManager {
    private var windows: [CGDirectDisplayID: DesktopWindow] = [:]
    private var quote: Quote?
    private var configuration: PresentationConfiguration?
    private var isVisible = true
    private var overflowByScreen: [CGDirectDisplayID: Bool] = [:]
    private var reportedOverflow = false
    var onOverflowChanged: ((Bool) -> Void)?

    func update(quote: Quote?, configuration: PresentationConfiguration, visible: Bool) {
        self.quote = quote
        self.configuration = configuration
        isVisible = visible
        reconcileScreens()
    }

    func reconcileScreens() {
        let screens = NSScreen.screens
        let activeIDs = Set(screens.compactMap(Self.displayID))
        for id in windows.keys.filter({ !activeIDs.contains($0) }) {
            windows[id]?.orderOut(nil)
            windows.removeValue(forKey: id)
            overflowByScreen.removeValue(forKey: id)
        }
        guard let configuration else { return }
        for screen in screens {
            guard let id = Self.displayID(screen) else { continue }
            let window = windows[id] ?? makeWindow(for: screen)
            windows[id] = window
            window.setFrame(screen.frame, display: true)
            if let view = window.contentView as? QuoteSurfaceView {
                view.quote = quote
                view.configuration = configuration
                view.onOverflowChanged = { [weak self] overflow in
                    self?.overflowByScreen[id] = overflow
                    self?.reportAggregateOverflow()
                }
                view.needsDisplay = true
            }
            if isVisible && configuration.visible && quote != nil {
                window.orderFrontRegardless()
            } else {
                window.orderOut(nil)
                overflowByScreen[id] = false
            }
        }
        reportAggregateOverflow()
    }

    private func reportAggregateOverflow() {
        let overflow = overflowByScreen.values.contains(true)
        guard reportedOverflow != overflow else { return }
        reportedOverflow = overflow
        onOverflowChanged?(overflow)
    }

    private func makeWindow(for screen: NSScreen) -> DesktopWindow {
        let window = DesktopWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = QuoteSurfaceView(frame: NSRect(origin: .zero, size: screen.frame.size))
        return window
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

private final class QuoteSurfaceView: NSView {
    var quote: Quote?
    var configuration: PresentationConfiguration?
    var onOverflowChanged: ((Bool) -> Void)?
    private var reportedOverflow: Bool?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let quote, let configuration else { return }
        let marginX = min(CGFloat(configuration.screenMargin), bounds.width / 2)
        let marginY = min(CGFloat(configuration.screenMargin), bounds.height / 2)
        let maxWidth = max(0, min(bounds.width * configuration.maximumWidthRatio, bounds.width - 2 * marginX))
        let maxHeight = max(0, min(bounds.height * configuration.maximumHeightRatio, bounds.height - 2 * marginY))
        guard maxWidth > 48, maxHeight > 32 else { reportOverflow(true); return }

        let quoteText = quote.text
        let authorText = quote.attribution.map { "— \($0)" } ?? ""
        let contentWidth = max(1, maxWidth - 48)
        let contentHeight = max(1, maxHeight - 32)
        let gap: CGFloat = authorText.isEmpty ? 0 : min(12, contentHeight)
        var fontSize = configuration.preferredFontSize
        var quoteSize = CGSize.zero
        var authorSize = CGSize.zero
        while true {
            quoteSize = measure(quoteText, font: font(size: fontSize, configuration: configuration), width: contentWidth)
            authorSize = measure(authorText, font: font(size: max(1, Int((Double(fontSize) * 0.85).rounded())), configuration: configuration), width: contentWidth)
            if quoteSize.height + authorSize.height + gap <= contentHeight || fontSize <= configuration.minimumFontSize { break }
            fontSize -= 1
        }
        let quoteFont = font(size: fontSize, configuration: configuration)
        let authorFont = font(size: max(1, Int((Double(fontSize) * 0.85).rounded())), configuration: configuration)
        let overflow = quoteSize.height + authorSize.height + gap > contentHeight
        let availableTextHeight = max(0, contentHeight - gap)
        let totalMeasuredHeight = quoteSize.height + authorSize.height
        let quoteHeight = overflow && totalMeasuredHeight > 0
            ? availableTextHeight * quoteSize.height / totalMeasuredHeight : quoteSize.height
        let authorHeight = authorText.isEmpty ? 0 : (overflow ? max(0, availableTextHeight - quoteHeight) : authorSize.height)
        let visibleQuote = overflow ? truncated(quoteText, font: quoteFont, width: contentWidth, height: quoteHeight) : quoteText
        let visibleAuthor = overflow ? truncated(authorText, font: authorFont, width: contentWidth, height: authorHeight) : authorText
        let intrinsicWidth = max(intrinsic(visibleQuote, font: quoteFont), intrinsic(visibleAuthor, font: authorFont)) + 48
        let cardWidth = min(maxWidth, max(48, intrinsicWidth))
        let cardHeight = min(maxHeight, quoteHeight + authorHeight + gap + 32)
        let x: CGFloat
        switch configuration.horizontalAlignment {
        case "left": x = marginX
        case "center": x = (bounds.width - cardWidth) / 2
        default: x = bounds.width - cardWidth - marginX
        }
        let y = max(marginY, min(bounds.height - cardHeight - marginY,
                                   bounds.height * configuration.verticalPositionRatio - cardHeight / 2))
        let card = NSRect(x: x, y: y, width: cardWidth, height: cardHeight)
        if configuration.shadow {
            NSColor(deviceWhite: 0, alpha: 0.4).setFill()
            NSBezierPath(roundedRect: card.offsetBy(dx: 4, dy: 4), xRadius: 8, yRadius: 8).fill()
        }
        configuration.cardColor.setFill()
        NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()
        let textWidth = max(1, card.width - 48)
        drawText(visibleQuote, font: quoteFont, color: configuration.quoteColor,
                 rect: NSRect(x: card.minX + 24, y: card.minY + 16, width: textWidth, height: quoteHeight),
                 alignment: .left)
        if !visibleAuthor.isEmpty {
            drawText(visibleAuthor, font: authorFont, color: configuration.authorColor,
                     rect: NSRect(x: card.minX + 24, y: card.minY + 16 + quoteHeight + gap,
                                  width: textWidth, height: authorHeight), alignment: .right)
        }
        reportOverflow(overflow)
    }

    private func font(size: Int, configuration: PresentationConfiguration) -> NSFont {
        NSFont(name: configuration.fontName, size: CGFloat(size))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    private func styled(_ text: String, font: NSFont, color: NSColor = .white,
                        alignment: NSTextAlignment = .left) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.alignment = alignment
        return NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style
        ])
    }

    private func measure(_ text: String, font: NSFont, width: CGFloat) -> CGSize {
        guard !text.isEmpty else { return .zero }
        return styled(text, font: font).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
    }

    private func intrinsic(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return styled(text, font: font).size().width
    }

    private func truncated(_ text: String, font: NSFont, width: CGFloat, height: CGFloat) -> String {
        guard measure(text, font: font, width: width).height > height else { return text }
        let characters = Array(text)
        var low = 0
        var high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = String(characters.prefix(middle)) + "…"
            if measure(candidate, font: font, width: width).height <= height { low = middle }
            else { high = middle - 1 }
        }
        return low == 0 ? "…" : String(characters.prefix(low)) + "…"
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, rect: NSRect,
                          alignment: NSTextAlignment) {
        styled(text, font: font, color: color, alignment: alignment)
            .draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private func reportOverflow(_ overflow: Bool) {
        guard reportedOverflow != overflow else { return }
        reportedOverflow = overflow
        DispatchQueue.main.async { [weak self] in self?.onOverflowChanged?(overflow) }
    }
}

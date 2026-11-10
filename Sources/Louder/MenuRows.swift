import AppKit
import LouderCore

/// Custom menu rows, modelled on the system's Wi-Fi/Bluetooth/Sound menus: everything else in
/// the menu is a stock NSMenuItem, so the system draws the glass, margins, shadow and animation.
enum MenuMetrics {
    /// Where stock menu item text starts and ends, measured from the menu's edge. Labels sit
    /// 2pt further out because NSTextField pads its text by that much.
    static let contentInset: CGFloat = 16
    static let labelInset: CGFloat = contentInset - 2
    static let width: CGFloat = 260
    /// Stock item geometry, measured from the menu's edge.
    static let rowHeight: CGFloat = 24
    /// Where stock text starts while some stock item shows a checkmark column.
    static let checkedTextInset: CGFloat = 30
    static let highlightInset: CGFloat = 5
    /// With continuous (squircle) corners; at 7 pt this matches the stock highlight pixel for pixel.
    static let highlightRadius: CGFloat = 7
}

/// Title on the left, switch on the right, like the header of the Wi-Fi menu.
final class ToggleRow: NSView {
    var onToggle: ((Bool) -> Void)?
    private let titleField = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()

    var isOn: Bool {
        get { toggle.state == .on }
        set { toggle.state = newValue ? .on : .off }
    }

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 32))
        autoresizingMask = .width
        titleField.stringValue = title
        titleField.font = .menuFont(ofSize: 0).bold
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggled)
        addSubview(titleField)
        addSubview(toggle)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let switchSize = toggle.fittingSize
        toggle.frame = NSRect(x: bounds.width - MenuMetrics.contentInset - switchSize.width, y: (bounds.height - switchSize.height) / 2, width: switchSize.width, height: switchSize.height)
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        titleField.frame = NSRect(x: MenuMetrics.labelInset, y: (bounds.height - titleHeight) / 2, width: toggle.frame.minX - 8 - MenuMetrics.labelInset, height: titleHeight)
    }

    @objc private func toggled() {
        onToggle?(isOn)
    }
}

/// The boost level: a large rounded readout above a slider flanked by speaker glyphs.
/// The slider moves in decibels, so equal distances sound like equal steps; the readout
/// stays a percentage, snapped to 5%.
final class LevelRow: NSView {
    var onChange: ((Float) -> Void)?
    private let valueField = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: Double(Level.maximumDecibels), target: nil, action: nil)
    private let quietIcon = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.1.fill", accessibilityDescription: nil)!)
    private let loudIcon = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)!)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 76))
        autoresizingMask = .width
        valueField.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold).rounded
        slider.target = self
        slider.action = #selector(slid)
        slider.isContinuous = true
        for icon in [quietIcon, loudIcon] {
            icon.contentTintColor = .secondaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        }
        // Pin the glyphs to the row's edges so they line up with the text above.
        quietIcon.imageAlignment = .alignLeft
        loudIcon.imageAlignment = .alignRight
        for view in [valueField, quietIcon, slider, loudIcon] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(gain: Float, enabled: Bool) {
        slider.doubleValue = Double(Level.decibels(gain))
        valueField.stringValue = Self.format(gain)
        valueField.textColor = enabled ? .labelColor : .tertiaryLabelColor
    }

    override func layout() {
        super.layout()
        let inset = MenuMetrics.contentInset
        let valueHeight = ceil(valueField.intrinsicContentSize.height)
        // The field reserves ascender room above the digits, which sat them visibly low.
        // Lift them so they're optically centred between the title row and the slider.
        valueField.frame = NSRect(x: MenuMetrics.labelInset - 2, y: -2.5, width: bounds.width - 2 * MenuMetrics.labelInset, height: valueHeight)

        let sliderHeight = ceil(slider.fittingSize.height)
        let sliderY = valueHeight + 6
        let icon: CGFloat = 16
        quietIcon.frame = NSRect(x: inset, y: sliderY + (sliderHeight - icon) / 2, width: icon, height: icon)
        loudIcon.frame = NSRect(x: bounds.width - inset - icon, y: quietIcon.frame.minY, width: icon, height: icon)
        slider.frame = NSRect(x: quietIcon.frame.maxX + 8, y: sliderY, width: loudIcon.frame.minX - 8 - quietIcon.frame.maxX - 8, height: sliderHeight)
    }

    @objc private func slid() {
        let gain = Level.snapped(Level.gain(decibels: Float(slider.doubleValue)))
        valueField.stringValue = Self.format(gain)
        onChange?(gain)
    }

    static func format(_ gain: Float) -> String {
        "\(Int((gain * 100).rounded()))%"
    }
}

private extension NSFont {
    var bold: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }

    var rounded: NSFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

/// A checkable row that toggles in place. A stock item closes the menu when clicked, which
/// makes picking several apps a reopen-per-app chore. Clicks on a view item don't close the
/// menu, so this row reproduces the stock look (text inset, hover highlight) and reports
/// clicks instead. The checkmark sits at the trailing edge, like a selection in Control
/// Center, because the leading checkmark column only exists while a stock item is checked.
///
/// AppKit doesn't redraw view items when their highlight changes, so the row tracks the
/// mouse itself to draw the accent-coloured hover highlight.
final class CheckRow: NSView {
    var onClick: (() -> Void)?
    var isChecked = false {
        didSet {
            checkmark.isHidden = !isChecked
            setAccessibilityValue(isChecked)
        }
    }

    private let checkmark = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)!)
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    /// A layer, not a drawn path: only Core Animation draws the continuous corners stock menus use.
    private let highlight = NSView()

    /// `detail` is shown in secondary text before the checkmark, like a stock item's shortcut.
    init(title: String, detail: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: MenuMetrics.rowHeight))
        autoresizingMask = .width
        titleField.stringValue = title
        titleField.font = .menuFont(ofSize: 0)
        titleField.lineBreakMode = .byTruncatingTail
        detailField.stringValue = detail ?? ""
        detailField.font = .menuFont(ofSize: 0)
        detailField.alignment = .right
        checkmark.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        checkmark.isHidden = true
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = MenuMetrics.highlightRadius
        highlight.layer?.cornerCurve = .continuous
        highlight.isHidden = true
        for view in [highlight, checkmark, titleField, detailField] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var isHovered = false {
        didSet { if isHovered != oldValue { applyHighlight() } }
    }
    private var isHighlighted: Bool { isHovered || (enclosingMenuItem?.isHighlighted ?? false) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Rows are reused across openings; none should reopen still lit.
        isHovered = false
        applyHighlight()
        // The stock checkmark column may have come or gone since the last opening.
        needsLayout = true
    }

    /// Where the stock items' text starts: further in while any of them shows a checkmark.
    private var textInset: CGFloat {
        let stockColumn = enclosingMenuItem?.menu?.items.contains { $0.view == nil && $0.state != .off } ?? false
        return stockColumn ? MenuMetrics.checkedTextInset : MenuMetrics.contentInset
    }

    override func layout() {
        super.layout()
        let textHeight = ceil(titleField.intrinsicContentSize.height)
        let textY = (bounds.height - textHeight) / 2
        let checkSize: CGFloat = 14
        checkmark.frame = NSRect(x: bounds.width - MenuMetrics.contentInset - checkSize, y: (bounds.height - checkSize) / 2, width: checkSize, height: checkSize)
        let detailWidth = detailField.stringValue.isEmpty ? 0 : ceil(detailField.intrinsicContentSize.width)
        detailField.frame = NSRect(x: checkmark.frame.minX - 6 - detailWidth, y: textY, width: detailWidth, height: textHeight)
        highlight.frame = bounds.insetBy(dx: MenuMetrics.highlightInset, dy: 0)
        let titleX = textInset - 2
        titleField.frame = NSRect(x: titleX, y: textY, width: detailField.frame.minX - 8 - titleX, height: textHeight)
    }

    private func applyHighlight() {
        let highlighted = isHighlighted
        highlight.isHidden = !highlighted
        // Stock menus highlight in the plain accent colour, not the darker selection colour.
        highlight.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        let text: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        titleField.textColor = text
        checkmark.contentTintColor = text
        detailField.textColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyHighlight()
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

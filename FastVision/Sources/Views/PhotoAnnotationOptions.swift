import AppKit

/// Style controls for the selected tool in the floating palette.
final class PhotoAnnotationOptions: NSVisualEffectView, NSComboBoxDelegate {
    var onTextStyleChange: (() -> Void)?
    var onStrokeStyleChange: (() -> Void)?

    struct Settings {
        let stroke: PhotoAnnotationStrokeStyle
        let arrow: Bool
        let tip: PhotoBrushTip
        let text: PhotoAnnotationTextStyle
    }
    private static let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    }

    private let pattern = NSPopUpButton()
    private let nib = NSPopUpButton()
    private let arrow = NSButton(checkboxWithTitle: NSLocalizedString("photo-editor-markup-arrow", value: "Arrow", comment: ""),
                                 target: nil, action: nil)
    private let width = NSComboBox()
    private let strokeColor = NSColorWell()
    private let strokeOutline = NSButton(checkboxWithTitle: NSLocalizedString("photo-editor-markup-outline", value: "Outline", comment: ""),
                                        target: nil, action: nil)
    private let font = NSPopUpButton()
    private let size = NSComboBox()
    private let textColor = NSColorWell()
    private let textOutline = NSButton(checkboxWithTitle: NSLocalizedString("photo-editor-markup-outline", value: "Outline", comment: ""),
                                       target: nil, action: nil)

    private let row = NSStackView()
    private var strokeFields: [NSView] = []
    private var textFields: [NSView] = []
    private var brushFields: [NSView] = []
    private var presentingSettings = false
    private var currentTool: AnnotationTool?
    private let patternTitles = [
        NSLocalizedString("photo-editor-stroke-solid", value: "Solid", comment: ""),
        NSLocalizedString("photo-editor-stroke-dashed", value: "Dashed", comment: ""),
        NSLocalizedString("photo-editor-stroke-dash-dot", value: "Dash-Dot", comment: ""),
    ]
    private let defaultWidth = 4
    private var defaultSize = 32

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        for style in PhotoAnnotationLinePattern.allCases {
            let title = patternTitles[style.rawValue]
            pattern.addItem(withTitle: title)
            pattern.lastItem?.image = patternSample(style, title: title)
        }
        arrow.controlSize = .small
        arrow.toolTip = arrow.title
        nib.addItems(withTitles: [
            NSLocalizedString("photo-editor-brush-round", value: "Round", comment: ""),
            NSLocalizedString("photo-editor-brush-square", value: "Square", comment: ""),
            NSLocalizedString("photo-editor-brush-flat", value: "Flat", comment: ""),
        ])
        font.addItem(withTitle: NSLocalizedString("photo-editor-system-font", value: "System Font", comment: ""))
        (font.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        configure(width, values: [1, 2, 4, 6, 8, 12, 16, 24, 32, 48, 64], initial: defaultWidth)
        configure(size, values: [12, 16, 24, 32, 48, 64, 96, 128, 192, 256], initial: defaultSize)
        for control in [font, size, textColor, textOutline] as [NSControl] {
            control.target = self
            control.action = #selector(textStyleChanged(_:))
        }
        for control in [pattern, nib, arrow, width, strokeColor, strokeOutline] as [NSControl] {
            control.target = self
            control.action = #selector(strokeStyleChanged(_:))
        }
        for toggle in [strokeOutline, textOutline] {
            toggle.controlSize = .small
            toggle.state = .off
            toggle.toolTip = NSLocalizedString("photo-editor-markup-outline-help", value: "Add a contrasting outline", comment: "")
        }
        size.delegate = self
        width.delegate = self
        textColor.isContinuous = true
        for color in [strokeColor, textColor] {
            color.color = NSColor(cgColor: PhotoAnnotation.defaultInk) ?? .red
            if #available(macOS 13, *) { color.colorWellStyle = .minimal }
            color.widthAnchor.constraint(equalToConstant: 34).isActive = true
        }

        let colorLabel = NSLocalizedString("photo-editor-markup-color", value: "Color", comment: "")
        strokeFields = [
            field(NSLocalizedString("photo-editor-stroke-pattern", value: "Style", comment: ""), pattern),
            field(NSLocalizedString("photo-editor-stroke-width", value: "Width", comment: ""), width, pixelUnits: true),
            field(colorLabel, strokeColor), strokeOutline,
        ]
        brushFields = [field(NSLocalizedString("photo-editor-brush-tip", value: "Tip", comment: ""), nib)]
            + strokeFields.dropFirst()
        textFields = [
            field(NSLocalizedString("photo-editor-markup-font", value: "Font", comment: ""), font),
            field(NSLocalizedString("photo-editor-markup-size", value: "Size", comment: ""), size, pixelUnits: true),
            field(colorLabel, textColor), textOutline,
        ]
        font.widthAnchor.constraint(equalToConstant: 152).isActive = true

        row.spacing = 13
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        show(for: .rectangle)
    }

    required init?(coder: NSCoder) { nil }

    func setInitialSizes(for imageSize: CGSize) {
        let shortSide = min(imageSize.width, imageSize.height)
        defaultSize = Int(max(8, min(1024, (shortSide * 0.04).rounded())))
        width.stringValue = String(defaultWidth)
        size.stringValue = String(defaultSize)
    }

    func show(for tool: AnnotationTool) {
        guard tool != currentTool else { return }
        currentTool = tool
        if tool == .text { populateFonts() }
        for field in row.arrangedSubviews {
            row.removeArrangedSubview(field)
            field.removeFromSuperview()
        }
        let fields: [NSView]
        switch tool {
        case .selection: fields = []
        case .text: fields = textFields
        case .brush: fields = brushFields
        default: fields = strokeFields
        }
        fields.forEach(row.addArrangedSubview)
        if tool == .line { row.insertArrangedSubview(arrow, at: 1) }
    }

    var hasArrow: Bool { arrow.state == .on }
    var brushTip: PhotoBrushTip { PhotoBrushTip(rawValue: nib.indexOfSelectedItem) ?? .round }

    var settings: Settings { Settings(stroke: strokeStyle, arrow: hasArrow, tip: brushTip, text: textStyle) }

    func restore(_ settings: Settings) {
        showStroke(settings.stroke, shape: .line(arrow: settings.arrow))
        nib.selectItem(at: settings.tip.rawValue)
        showText(settings.text)
    }

    func showStroke(_ style: PhotoAnnotationStrokeStyle, shape: PhotoAnnotationStroke.Shape) {
        presentingSettings = true
        defer { presentingSettings = false }
        if case let .brush(tip) = shape {
            nib.selectItem(at: tip.rawValue)
        } else {
            pattern.selectItem(at: style.pattern.rawValue)
        }
        if case let .line(hasArrow) = shape { arrow.state = hasArrow ? .on : .off }
        width.stringValue = String(Int(style.width.rounded()))
        strokeColor.color = NSColor(cgColor: style.color) ?? .red
        strokeOutline.state = style.outlined ? .on : .off
    }

    func showText(_ style: PhotoAnnotationTextStyle) {
        presentingSettings = true
        defer { presentingSettings = false }
        if let fontName = style.fontName, let family = NSFont(name: fontName, size: style.size)?.familyName {
            populateFonts()
            font.selectItem(withTitle: family)
        } else {
            font.selectItem(at: 0)
        }
        size.stringValue = String(Int(style.size.rounded()))
        textColor.color = NSColor(cgColor: style.color) ?? .red
        textOutline.state = style.outlined ? .on : .off
    }

    private func populateFonts() {
        guard font.numberOfItems == 1 else { return }
        font.addItems(withTitles: Self.fontFamilies)
        for item in font.itemArray.dropFirst() { item.representedObject = item.title }
    }

    func setEnabled(_ enabled: Bool) {
        for control in [pattern, nib, arrow, width, strokeColor, strokeOutline, font, size, textColor, textOutline] as [NSControl] {
            control.isEnabled = enabled
        }
    }

    var strokeStyle: PhotoAnnotationStrokeStyle {
        PhotoAnnotationStrokeStyle(width: pixels(width, bounds: 1...512, defaultValue: defaultWidth),
                                   pattern: PhotoAnnotationLinePattern(rawValue: pattern.indexOfSelectedItem) ?? .solid,
                                   color: ink(strokeColor), outlined: strokeOutline.state == .on)
    }

    var textStyle: PhotoAnnotationTextStyle {
        let pointSize = pixels(size, bounds: 6...1024, defaultValue: defaultSize)
        let family = font.selectedItem?.representedObject as? String
        let fontName = family.flatMap {
            NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: pointSize)?.fontName
        }
        return PhotoAnnotationTextStyle(fontName: fontName, size: pointSize, color: ink(textColor), outlined: textOutline.state == .on)
    }

    func hasTextFocus(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSView, view.isDescendant(of: self) { return true }
        guard let responder else { return false }
        return responder === size.currentEditor()
    }

    @objc private func textStyleChanged(_ sender: NSControl) {
        if !presentingSettings { onTextStyleChange?() }
    }

    @objc private func strokeStyleChanged(_ sender: NSControl) {
        if !presentingSettings { onStrokeStyleChange?() }
    }

    func controlTextDidChange(_ notification: Notification) {
        if let control = notification.object as? NSControl { notifyStyleChange(for: control) }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard !presentingSettings, let control = notification.object as? NSControl else { return }
        DispatchQueue.main.async { [weak self, weak control] in
            if let control { self?.notifyStyleChange(for: control) }
        }
    }

    private func notifyStyleChange(for control: NSControl) {
        if control === size { textStyleChanged(control) }
        if control === width { strokeStyleChanged(control) }
    }

    private func patternSample(_ style: PhotoAnnotationLinePattern, title: String) -> NSImage {
        let sample = NSImage(size: NSSize(width: 43, height: 13), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let width: CGFloat = 1.7
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineDash(phase: 0, lengths: style.lengths(for: width))
            context.move(to: CGPoint(x: rect.minX + 2, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.midY))
            context.strokePath()
            return true
        }
        sample.isTemplate = true
        sample.accessibilityDescription = title
        return sample
    }

    private func configure(_ input: NSComboBox, values: [Int], initial: Int) {
        input.addItems(withObjectValues: values.map(String.init))
        input.stringValue = String(initial)
        input.widthAnchor.constraint(equalToConstant: 67).isActive = true
    }

    private func pixels(_ input: NSComboBox, bounds: ClosedRange<Int>, defaultValue: Int) -> CGFloat {
        let text = input.currentEditor()?.string ?? input.stringValue
        let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultValue
        let clamped = max(bounds.lowerBound, min(bounds.upperBound, value))
        return CGFloat(clamped)
    }

    private func ink(_ well: NSColorWell) -> CGColor {
        well.color.usingColorSpace(.sRGB)?.withAlphaComponent(1).cgColor ?? PhotoAnnotation.defaultInk
    }

    private func field(_ title: String, _ control: NSControl, pixelUnits: Bool = false) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        control.controlSize = .small
        control.setAccessibilityLabel(title)
        control.toolTip = title
        var views: [NSView] = [label, control]
        if pixelUnits {
            let units = NSTextField(labelWithString: "px")
            units.textColor = .secondaryLabelColor
            units.font = label.font
            views.append(units)
        }
        let field = NSStackView(views: views)
        field.spacing = 5
        field.alignment = .centerY
        return field
    }
}

enum AnnotationTool: Int, CaseIterable {
    case selection, rectangle, circle, line, text, brush

    var title: String {
        switch self {
        case .selection: return NSLocalizedString("photo-editor-markup-selection", value: "Select", comment: "")
        case .rectangle: return NSLocalizedString("photo-editor-markup-rectangle", value: "Rectangle", comment: "")
        case .circle: return NSLocalizedString("photo-editor-markup-circle", value: "Circle", comment: "")
        case .line: return NSLocalizedString("photo-editor-markup-line", value: "Line", comment: "")
        case .text: return NSLocalizedString("photo-editor-markup-text", value: "Text", comment: "")
        case .brush: return NSLocalizedString("photo-editor-markup-brush", value: "Brush", comment: "")
        }
    }

    var symbol: String? {
        switch self {
        case .selection: return "plus"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .line: return "line.diagonal"
        case .text: return nil
        case .brush: return "paintbrush.pointed"
        }
    }
}

final class PhotoAnnotationPalette: NSView {
    let options = PhotoAnnotationOptions()
    var onToolChange: ((AnnotationTool) -> Void)?

    private let header = NSVisualEffectView()
    private let tools = NSSegmentedControl()
    private var offset: CGPoint?

    override var isFlipped: Bool { true }
    var selectedTool: AnnotationTool { AnnotationTool(rawValue: tools.selectedSegment) ?? .selection }

    init() {
        super.init(frame: .zero)
        isHidden = true

        header.material = .popover
        header.blendingMode = .withinWindow
        header.state = .active
        header.wantsLayer = true
        header.layer?.cornerRadius = 10
        header.layer?.masksToBounds = true
        tools.segmentCount = AnnotationTool.allCases.count
        tools.trackingMode = .selectOne
        for tool in AnnotationTool.allCases {
            let index = tool.rawValue
            if let symbol = tool.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tool.title) {
                tools.setImage(image, forSegment: index)
            } else {
                tools.setLabel(tool == .text ? "A" : tool.title, forSegment: index)
            }
            tools.setWidth(34, forSegment: index)
            tools.setToolTip(tool.title, forSegment: index)
        }
        tools.target = self
        tools.action = #selector(selectTool(_:))
        tools.selectedSegment = AnnotationTool.selection.rawValue
        tools.setAccessibilityLabel(NSLocalizedString("photo-editor-annotation", value: "Markup", comment: ""))

        let grip = PhotoAnnotationPaletteGrip()
        grip.onMove = { [weak self] delta in self?.move(by: delta) }
        let row = NSStackView(views: [grip, tools])
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -7),
            row.topAnchor.constraint(equalTo: header.topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -5),
            grip.widthAnchor.constraint(equalToConstant: 18),
            grip.heightAnchor.constraint(equalToConstant: 22),
        ])
        addSubview(header)
        addSubview(options)
    }

    required init?(coder: NSCoder) { nil }

    func show(tool: AnnotationTool?, settingsFor settingsTool: AnnotationTool?, enabled: Bool) {
        isHidden = tool == nil
        guard let tool else { return }
        tools.selectedSegment = tool.rawValue
        tools.isEnabled = enabled
        options.isHidden = settingsTool == nil || settingsTool == .selection
        if let settingsTool, settingsTool != .selection {
            options.show(for: settingsTool)
            options.setEnabled(enabled)
        }
        if let superview { place(in: superview.bounds) }
    }

    func place(in canvas: CGRect) {
        guard !isHidden else { return }
        let top = header.fittingSize
        let bottom = options.isHidden ? .zero : options.fittingSize
        let spacing: CGFloat = options.isHidden ? 0 : 4
        let size = NSSize(width: ceil(max(top.width, bottom.width)), height: ceil(top.height + spacing + bottom.height))
        let preferred = offset ?? CGPoint(x: (canvas.width - size.width) / 2, y: canvas.height - size.height - 8)
        let x = min(preferred.x, max(8, canvas.width - size.width - 8))
        let y = min(preferred.y, max(8, canvas.height - size.height - 8))
        frame = NSRect(origin: CGPoint(x: canvas.minX + max(8, x), y: canvas.minY + max(8, y)), size: size)
        header.frame = NSRect(origin: .zero, size: top)
        options.frame = NSRect(origin: CGPoint(x: 0, y: top.height + spacing), size: bottom)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    @objc private func selectTool(_ sender: NSSegmentedControl) { onToolChange?(selectedTool) }

    private func move(by delta: CGPoint) {
        guard let superview else { return }
        offset = CGPoint(x: frame.minX - superview.bounds.minX + delta.x,
                         y: frame.minY - superview.bounds.minY + delta.y)
        place(in: superview.bounds)
        offset = CGPoint(x: frame.minX - superview.bounds.minX, y: frame.minY - superview.bounds.minY)
    }
}

private final class PhotoAnnotationPaletteGrip: NSImageView {
    var onMove: ((CGPoint) -> Void)?
    private var lastMouseLocation = CGPoint.zero

    init() {
        super.init(frame: .zero)
        let label = NSLocalizedString("photo-editor-markup-drag-toolbar", value: "Drag Markup Toolbar", comment: "")
        image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: label)
        contentTintColor = .secondaryLabelColor
        toolTip = label
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { lastMouseLocation = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        onMove?(CGPoint(x: point.x - lastMouseLocation.x, y: lastMouseLocation.y - point.y))
        lastMouseLocation = point
    }
}

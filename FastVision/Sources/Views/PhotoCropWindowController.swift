import AppKit
import CoreImage
import UniformTypeIdentifiers

final class PhotoCropWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate {
    static let editorSymbol = "square.and.pencil"
    static var deleteAnnotationTitle: String {
        NSLocalizedString("photo-editor-delete-annotation", value: "Delete Annotation", comment: "")
    }

    private enum Tool {
        static let mode = NSToolbarItem.Identifier("crop.mode")
        static let ratio = NSToolbarItem.Identifier("crop.ratio")
        static let annotation = NSToolbarItem.Identifier("editor.annotation")
        static let reset = NSToolbarItem.Identifier("crop.reset")
        static let rotateLeft = NSToolbarItem.Identifier("editor.rotateLeft")
        static let rotateRight = NSToolbarItem.Identifier("editor.rotateRight")
        static let undo = NSToolbarItem.Identifier("crop.undo")
        static let apply = NSToolbarItem.Identifier("crop.apply")
        static let save = NSToolbarItem.Identifier("crop.save")
        static let saveAs = NSToolbarItem.Identifier("crop.saveAs")
    }

    private struct ImageState {
        let pixels: CIImage
        let display: CGImage
        let annotations: [PhotoAnnotationLayer]
        let revision = UUID()

        var compositedPixels: CIImage {
            guard !annotations.isEmpty else { return pixels }
            return annotations.reduce(pixels) { image, layer in layer.positionedPixels.composited(over: image) }
                .cropped(to: pixels.extent)
        }
    }

    private struct TextDraft {
        let field: NSTextField
        let anchor: CGPoint
        var style: PhotoAnnotationTextStyle

        var text: String {
            let input = field.currentEditor()?.string ?? field.stringValue
            return input.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
    }

    private struct Destination {
        let url: URL
        let type: UTType?
        let snapshot: SafeFileReplacement.Item
    }

    private static var openWindows: [PhotoCropWindowController] = []

    static var hasOpenEditors: Bool { !openWindows.isEmpty }

    static func open(_ url: URL) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = openWindows.first(where: { $0.destination?.url == url || ($0.destination == nil && $0.sourceURL == url) }) {
            existing.showWindow(nil)
            return
        }
        let editor = PhotoCropWindowController(url: url)
        openWindows.append(editor)
        editor.showWindow(nil)
        editor.loadPhoto()
    }

    static func allowTermination(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard !openWindows.contains(where: { $0.busy || $0.window?.attachedSheet != nil }) else { return .terminateCancel }
        for editor in openWindows { editor.finishText() }
        let unsaved = openWindows.filter(\.hasUnsavedChanges)
        guard !unsaved.isEmpty else { return .terminateNow }
        DispatchQueue.main.async {
            func confirmNext(_ index: Int) {
                guard index < unsaved.count else {
                    app.reply(toApplicationShouldTerminate: true)
                    return
                }
                let editor = unsaved[index]
                editor.showWindow(nil)
                editor.confirmChanges { proceed in
                    if proceed { confirmNext(index + 1) }
                    else { app.reply(toApplicationShouldTerminate: false) }
                }
            }
            confirmNext(0)
        }
        return .terminateLater
    }

    private let sourceURL: URL
    private let context = CIContext()
    private let history = UndoManager()
    private var imageState: ImageState?
    private var destination: Destination?
    private var textDraft: TextDraft?
    private var draftMouseMonitor: Any?
    private var draftFocusInPalette = false
    private var creationSettings: PhotoAnnotationOptions.Settings?
    private var savedRevision: UUID?
    private var busy = false
    private let canvas = PhotoCropCanvas()
    private let mode = NSSegmentedControl()
    private let annotationPalette = PhotoAnnotationPalette()
    private let aspect = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")

    private var cropAspect: PhotoCropAspect { PhotoCropAspect(rawValue: aspect.indexOfSelectedItem) ?? .free }
    private var ready: Bool { imageState != nil && !busy }
    private var hasUnsavedChanges: Bool {
        guard let imageState else { return false }
        return imageState.revision != savedRevision || textDraft?.text.isEmpty == false
    }

    var canSave: Bool { ready && hasUnsavedChanges }
    var canSaveAs: Bool { ready }
    var canApplyCrop: Bool { ready && canvas.mode != nil }
    var canUndoCrop: Bool { ready && history.canUndo }
    var canRedoCrop: Bool { ready && history.canRedo }
    var canDeleteAnnotation: Bool {
        ready && canvas.mode == nil && textDraft == nil && !canvas.selectedAnnotations.isEmpty && window?.attachedSheet == nil
    }

    init(url: URL) {
        sourceURL = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        history.levelsOfUndo = 8
        history.groupsByEvent = false
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.title = url.lastPathComponent
        window.representedURL = url
        window.minSize = CGSize(width: 610, height: 350)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        configureControls(in: window)
    }

    required init?(coder: NSCoder) { nil }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !busy, sender.attachedSheet == nil else { return false }
        finishText()
        guard hasUnsavedChanges else { return true }
        confirmChanges { [weak sender] proceed in
            if proceed { sender?.close() }
        }
        return false
    }

    func windowDidResignMain(_ notification: Notification) { finishText() }

    func windowWillClose(_ notification: Notification) {
        stopWatchingDraftClicks()
        Self.openWindows.removeAll { $0 === self }
    }

    private func configureControls(in window: NSWindow) {
        window.acceptsMouseMovedEvents = true
        let tools = [
            ("crop", NSLocalizedString("photo-editor-rectangle", value: "Crop", comment: "")),
            ("perspective", NSLocalizedString("photo-editor-perspective", value: "Perspective Crop", comment: "")),
        ]
        mode.segmentCount = tools.count
        mode.trackingMode = .selectOne
        for (index, (symbol, title)) in tools.enumerated() {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
                mode.setImage(image, forSegment: index)
                mode.setWidth(38, forSegment: index)
            } else {
                mode.setLabel(title, forSegment: index)
            }
            mode.setToolTip(title, forSegment: index)
        }
        mode.setAccessibilityLabel(NSLocalizedString("photo-editor-tool", value: "Crop Tool", comment: ""))
        mode.target = self
        mode.action = #selector(changeMode(_:))
        mode.selectedSegment = -1
        aspect.addItems(withTitles: [
            NSLocalizedString("photo-editor-free-ratio", value: "Free Ratio", comment: ""),
            NSLocalizedString("photo-editor-original-ratio", value: "Original Ratio", comment: ""),
        ])
        aspect.target = self
        aspect.action = #selector(changeRatio(_:))
        aspect.selectItem(at: PhotoCropAspect.free.rawValue)
        let ratioLabel = NSLocalizedString("photo-editor-ratio", value: "Crop Aspect Ratio", comment: "")
        aspect.toolTip = ratioLabel
        aspect.setAccessibilityLabel(ratioLabel)

        let toolbar = NSToolbar(identifier: "FastVision.PhotoEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbarStyle = .unified
        window.toolbar = toolbar

        let root = NSView()
        window.contentView = root
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        canvas.onApply = { [weak self] in self?.applyCrop(nil) }
        canvas.addSubview(annotationPalette)
        canvas.floatingPalette = annotationPalette
        annotationPalette.onToolChange = { [weak self] tool in self?.selectAnnotation(tool) }
        annotationPalette.options.onTextStyleChange = { [weak self] in self?.textStyleChanged() }
        annotationPalette.options.onStrokeStyleChange = { [weak self] in self?.strokeStyleChanged() }
        canvas.onSelectAnnotations = { [weak self] in self?.showAnnotationProperties() }
        canvas.makeStroke = { [weak self] tool, point in self?.makeStroke(tool: tool, start: point) }
        canvas.onStroke = { [weak self] tool, stroke in self?.addStroke(stroke, using: tool) }
        canvas.onText = { [weak self] anchor in self?.beginText(at: anchor) }
        canvas.onMoveAnnotations = { [weak self] layers in self?.moveAnnotations(layers) }
        canvas.onDeleteAnnotation = { [weak self] in self?.deleteSelectedAnnotation(nil) }
        canvas.onLayout = { [weak self] in self?.layoutTextDraft() }
        canvas.wantsLayer = true
        canvas.layer?.masksToBounds = true
        for item in [canvas, status] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        syncControls()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Tool.mode, Tool.ratio, Tool.reset, Tool.apply, .space, Tool.rotateLeft, Tool.rotateRight, .space,
         Tool.annotation, .flexibleSpace, Tool.undo, .space, Tool.save, Tool.saveAs]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.autovalidates = false
        item.target = self
        switch identifier {
        case Tool.mode:
            item.label = NSLocalizedString("photo-editor-tool", value: "Crop Tool", comment: "")
            item.view = mode
        case Tool.ratio:
            item.label = NSLocalizedString("photo-editor-ratio", value: "Crop Aspect Ratio", comment: "")
            item.view = aspect
        case Tool.annotation:
            item.label = NSLocalizedString("photo-editor-annotation", value: "Markup", comment: "")
            item.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: item.label)
            item.action = #selector(toggleMarkup(_:))
        case Tool.reset:
            item.label = NSLocalizedString("photo-editor-reset", value: "Reset", comment: "")
            item.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: item.label)
            item.action = #selector(resetSelection(_:))
        case Tool.rotateLeft, Tool.rotateRight:
            let clockwise = identifier == Tool.rotateRight
            item.label = rotationLabel(clockwise: clockwise)
            item.image = NSImage(systemSymbolName: clockwise ? "rotate.right" : "rotate.left", accessibilityDescription: item.label)
            item.action = clockwise ? #selector(rotateRight(_:)) : #selector(rotateLeft(_:))
            item.visibilityPriority = .high
        case Tool.undo:
            item.label = NSLocalizedString("Undo", comment: "")
            item.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: item.label)
            item.action = #selector(undoCrop(_:))
        case Tool.apply:
            item.label = NSLocalizedString("photo-editor-apply", value: "Apply Crop", comment: "")
            item.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: item.label)
            item.action = #selector(applyCrop(_:))
            item.visibilityPriority = .high
        case Tool.save:
            item.label = NSLocalizedString("photo-editor-save", value: "Save", comment: "")
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: item.label)
            item.action = #selector(saveDocument(_:))
            item.visibilityPriority = .high
        case Tool.saveAs:
            item.label = NSLocalizedString("photo-editor-save-as", value: "Save As", comment: "")
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: item.label)
            item.action = #selector(saveDocumentAs(_:))
            item.visibilityPriority = .high
        default:
            return nil
        }
        item.toolTip = item.label
        return item
    }

    private func loadPhoto() {
        busy = true
        status.stringValue = NSLocalizedString("photo-editor-loading", value: "Opening photo…", comment: "")
        syncControls()
        let url = sourceURL, context = self.context
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> (PhotoCropProcessor.LoadedPhoto, CGImage) in
                let photo = try PhotoCropProcessor.load(url)
                return (photo, try PhotoCropProcessor.render(photo.image, context: context, maximumSide: 1800))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                switch result {
                case let .success((photo, display)):
                    let state = ImageState(pixels: photo.image, display: display, annotations: [])
                    self.imageState = state
                    self.annotationPalette.options.setInitialSizes(for: state.pixels.extent.size)
                    self.savedRevision = state.revision
                    self.destination = Destination(url: url, type: photo.writableType, snapshot: photo.snapshot)
                    self.canvas.image = state.display
                    self.canvas.imageSize = state.pixels.extent.size
                    self.showSelectionHelp()
                case let .failure(error):
                    self.status.stringValue = error.localizedDescription
                }
                self.syncControls()
                self.window?.makeFirstResponder(self.canvas)
            }
        }
    }

    private func syncControls() {
        mode.isEnabled = ready
        aspect.isEnabled = canApplyCrop
        let settingsTool = canvas.selectedAnnotations.count > 1 ? nil : selectedLayer.map(tool(for:)) ?? canvas.annotationTool
        annotationPalette.show(tool: canvas.annotationTool, settingsFor: settingsTool, enabled: ready)
        canvas.acceptsEditing = ready
        window?.isDocumentEdited = hasUnsavedChanges
        for item in window?.toolbar?.items ?? [] {
            switch item.itemIdentifier {
            case Tool.mode, Tool.rotateLeft, Tool.rotateRight: item.isEnabled = ready
            case Tool.annotation:
                item.isEnabled = ready
                let symbol = canvas.annotationTool == nil ? "pencil.tip.crop.circle" : "pencil.tip.crop.circle.fill"
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
            case Tool.ratio: item.isEnabled = aspect.isEnabled
            case Tool.undo: item.isEnabled = canUndoCrop
            case Tool.reset, Tool.apply: item.isEnabled = canApplyCrop
            case Tool.save: item.isEnabled = canSave
            case Tool.saveAs: item.isEnabled = canSaveAs
            default: break
            }
        }
    }

    private func showSelectionHelp() {
        if let tool = canvas.annotationTool {
            switch tool {
            case .selection:
                status.stringValue = NSLocalizedString("photo-editor-markup-selection-help", value: "Click an annotation or drag to select several.", comment: "")
            case .text:
                status.stringValue = NSLocalizedString("photo-editor-markup-text-help", value: "Click the photo to type. Press Return to place the text.", comment: "")
            default:
                status.stringValue = NSLocalizedString("photo-editor-markup-draw-help", value: "Drag on the photo to draw.", comment: "")
            }
        } else if let mode = canvas.mode {
            status.stringValue = mode == .rectangle
                ? NSLocalizedString("photo-editor-rectangle-help", value: "Drag a crop frame. Double-click inside it to apply.", comment: "")
                : NSLocalizedString("photo-editor-perspective-help", value: "Drag any square to adjust the frame. Double-click inside it to apply.", comment: "")
        } else {
            status.stringValue = hasUnsavedChanges
                ? NSLocalizedString("photo-editor-unsaved", value: "Unsaved changes", comment: "")
                : ""
        }
    }

    @objc private func toggleMarkup(_ sender: Any?) {
        guard ready else { return }
        finishText()
        if canvas.annotationTool == nil {
            selectAnnotation(annotationPalette.selectedTool)
        } else {
            canvas.selectedAnnotation = nil
            canvas.annotationTool = nil
            showSelectionHelp()
            syncControls()
        }
    }

    private func selectAnnotation(_ tool: AnnotationTool) {
        guard ready else { return }
        finishText()
        canvas.selectedAnnotation = nil
        dismissCrop()
        canvas.annotationTool = tool
        showSelectionHelp()
        syncControls()
    }

    private func makeStroke(tool: AnnotationTool, start: CGPoint) -> PhotoAnnotationStroke? {
        let options = annotationPalette.options
        let shape: PhotoAnnotationStroke.Shape
        switch tool {
        case .rectangle: shape = .rectangle
        case .circle: shape = .circle
        case .line: shape = .line(arrow: options.hasArrow)
        case .brush: shape = .brush(options.brushTip)
        case .selection, .text: return nil
        }
        let style = options.strokeStyle
        let ink = tool == .brush
            ? PhotoAnnotationStrokeStyle(width: style.width, pattern: .solid, color: style.color, outlined: style.outlined)
            : style
        return PhotoAnnotationStroke(start: start, end: start, shape: shape, style: ink)
    }

    private var selectedLayer: PhotoAnnotationLayer? {
        guard let id = canvas.selectedAnnotation else { return nil }
        return imageState?.annotations.first { $0.id == id }
    }

    private func tool(for layer: PhotoAnnotationLayer) -> AnnotationTool {
        switch layer.annotation {
        case let .stroke(stroke):
            switch stroke.shape {
            case .rectangle: return .rectangle
            case .circle: return .circle
            case .line: return .line
            case .brush: return .brush
            }
        case .text: return .text
        }
    }

    private func showAnnotationProperties() {
        let options = annotationPalette.options
        if let layer = selectedLayer {
            if creationSettings == nil { creationSettings = options.settings }
            if canvas.annotationTool == nil { canvas.annotationTool = .selection }
            switch layer.annotation {
            case let .stroke(stroke): options.showStroke(stroke.style, shape: stroke.shape)
            case let .text(_, _, style): options.showText(style)
            }
        } else if let creationSettings {
            options.restore(creationSettings)
            self.creationSettings = nil
        }
        showSelectionHelp()
        syncControls()
    }

    private func textStyleChanged() {
        if textDraft != nil {
            updateDraftStyle()
            return
        }
        guard let layer = selectedLayer, case let .text(text, anchor, existing) = layer.annotation else { return }
        let style = annotationPalette.options.textStyle
        if style != existing { restyle(layer, as: .text(text, anchor: anchor, style: style)) }
    }

    private func strokeStyleChanged() {
        guard let layer = selectedLayer, case var .stroke(stroke) = layer.annotation else { return }
        let options = annotationPalette.options
        let current = options.strokeStyle
        let oldStyle = stroke.style
        let oldShape = stroke.shape
        switch oldShape {
        case .line: stroke.shape = .line(arrow: options.hasArrow)
        case .brush: stroke.shape = .brush(options.brushTip)
        case .circle, .rectangle: break
        }
        if case .brush = stroke.shape {
            stroke.style = PhotoAnnotationStrokeStyle(width: current.width, pattern: .solid, color: current.color, outlined: current.outlined)
        } else {
            stroke.style = current
        }
        if stroke.style != oldStyle || stroke.shape != oldShape { restyle(layer, as: .stroke(stroke)) }
    }

    private func restyle(_ layer: PhotoAnnotationLayer, as annotation: PhotoAnnotation) {
        guard ready, let state = imageState, let index = state.annotations.firstIndex(where: { $0.id == layer.id }) else { return }
        do {
            var annotations = state.annotations
            annotations[index] = try layer.restyled(as: annotation, context: context)
            useImageState(ImageState(pixels: state.pixels, display: state.display, annotations: annotations),
                          actionName: NSLocalizedString("photo-editor-change-markup-style", value: "Change Annotation Style", comment: ""))
        } catch {
            show(error)
        }
    }

    @objc private func changeMode(_ sender: Any?) {
        guard ready, let cropMode = PhotoCropMode(rawValue: mode.selectedSegment) else { return }
        finishText()
        if canvas.mode == cropMode {
            dismissCrop()
            showSelectionHelp()
            syncControls()
            return
        }
        let frame = canvas.mode == nil
            ? canvas.marquee ?? PhotoCropSelection().bounds
            : canvas.selection.bounds
        canvas.annotationTool = nil
        canvas.marquee = nil
        mode.selectedSegment = cropMode.rawValue
        canvas.mode = cropMode
        let selection = PhotoCropSelection(rect: frame, aspect: cropMode == .rectangle ? cropAspect : .free)
        canvas.selection = selection.isValid ? selection : PhotoCropSelection()
        showSelectionHelp()
        syncControls()
    }

    @objc private func changeRatio(_ sender: Any?) {
        canvas.aspect = cropAspect
        if canvas.mode == .rectangle && cropAspect == .original {
            canvas.selection = PhotoCropSelection(rect: canvas.selection.bounds, aspect: cropAspect)
        }
    }

    @objc private func resetSelection(_ sender: Any?) {
        guard canApplyCrop else { return }
        canvas.selection = PhotoCropSelection()
        showSelectionHelp()
    }

    private func dismissCrop() {
        mode.selectedSegment = -1
        canvas.mode = nil
        canvas.marquee = nil
    }

    @objc func applyCrop(_ sender: Any?) {
        guard canApplyCrop, let mode = canvas.mode else { return }
        let selection = canvas.selection, aspect = cropAspect
        transformImage(named: NSLocalizedString("photo-editor-rectangle", value: "Crop", comment: "")) { image in
            try PhotoCropProcessor.crop(image, selection: selection, mode: mode, aspect: aspect)
        }
    }

    @objc private func rotateLeft(_ sender: Any?) { rotate(clockwise: false) }
    @objc private func rotateRight(_ sender: Any?) { rotate(clockwise: true) }

    private func rotationLabel(clockwise: Bool) -> String {
        clockwise
            ? NSLocalizedString("Rotate Clockwise", comment: "顺时针旋转")
            : NSLocalizedString("Rotate Counterclockwise", comment: "逆时针旋转")
    }

    private func rotate(clockwise: Bool) {
        finishText()
        transformImage(named: rotationLabel(clockwise: clockwise)) { image in
            PhotoCropProcessor.rotate(image, clockwise: clockwise)
        }
    }

    private func addStroke(_ stroke: PhotoAnnotationStroke, using tool: AnnotationTool) {
        let id = UUID()
        updateImage(named: tool.title, selecting: id) { state, context in
            let layer = try PhotoAnnotationLayer(id: id, annotation: .stroke(stroke), extent: state.pixels.extent, context: context)
            return ImageState(pixels: state.pixels, display: state.display, annotations: state.annotations + [layer])
        }
    }

    private func moveAnnotations(_ layers: [UUID: PhotoAnnotationLayer]) {
        guard ready, let state = imageState,
              state.annotations.contains(where: { layer in layers[layer.id].map { $0.offset != layer.offset } ?? false }) else { return }
        let moved = state.annotations.map { layers[$0.id] ?? $0 }
        useImageState(ImageState(pixels: state.pixels, display: state.display, annotations: moved),
                      actionName: NSLocalizedString("photo-editor-move-markup", value: "Move Annotation", comment: ""))
    }

    @objc func deleteSelectedAnnotation(_ sender: Any?) {
        guard canDeleteAnnotation, let state = imageState else { return }
        let selected = canvas.selectedAnnotations
        let annotations = state.annotations.filter { !selected.contains($0.id) }
        useImageState(ImageState(pixels: state.pixels, display: state.display, annotations: annotations),
                      actionName: Self.deleteAnnotationTitle)
    }

    private func beginText(at anchor: CGPoint) {
        guard ready, let window, window.attachedSheet == nil else { return }
        finishText()
        let style = annotationPalette.options.textStyle
        let field = PhotoInlineTextField(frame: .zero)
        field.delegate = self
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.usesSingleLineMode = true
        field.placeholderString = NSLocalizedString("photo-editor-markup-text-placeholder", value: "Enter annotation text", comment: "")
        field.setAccessibilityLabel(field.placeholderString)
        textDraft = TextDraft(field: field, anchor: anchor, style: style)
        canvas.addSubview(field, positioned: .above, relativeTo: annotationPalette)
        updateDraftStyle()
        window.makeFirstResponder(field)
        updateDraftStyle()
        watchDraftClicks()
    }

    private func watchDraftClicks() {
        draftMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let draft = self.textDraft, event.window === self.window else { return event }
            let location = event.locationInWindow
            let point = self.annotationPalette.convert(location, from: nil)
            self.draftFocusInPalette = !self.annotationPalette.isHidden && self.annotationPalette.bounds.contains(point)
            if !self.draftFocusInPalette, !draft.field.bounds.contains(draft.field.convert(location, from: nil)) {
                self.finishText()
            }
            return event
        }
    }

    private func stopWatchingDraftClicks() {
        if let draftMouseMonitor { NSEvent.removeMonitor(draftMouseMonitor) }
        draftMouseMonitor = nil
        draftFocusInPalette = false
    }

    private func updateDraftStyle() {
        guard var draft = textDraft else { return }
        draft.style = annotationPalette.options.textStyle
        textDraft = draft
        let color = NSColor(cgColor: draft.style.color) ?? .labelColor
        draft.field.textColor = color
        draft.field.backgroundColor = NSColor(cgColor: PhotoAnnotation.outline(for: draft.style.color)) ?? .textBackgroundColor
        if let editor = draft.field.currentEditor() as? NSTextView {
            editor.textColor = color
            editor.insertionPointColor = color
        }
        layoutTextDraft()
    }

    private func layoutTextDraft() {
        guard let draft = textDraft else { return }
        canvas.placeTextField(draft.field, at: draft.anchor, style: draft.style,
                              input: draft.field.currentEditor()?.string ?? draft.field.stringValue)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let draft = textDraft, notification.object as? NSTextField === draft.field else { return }
        layoutTextDraft()
        syncControls()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let draft = textDraft, notification.object as? NSTextField === draft.field, !draftFocusInPalette else { return }
        DispatchQueue.main.async { [weak self, weak field = draft.field] in
            guard let self, let field, self.textDraft?.field === field, !self.draftFocusInPalette,
                  field.currentEditor() == nil else { return }
            if self.annotationPalette.options.hasTextFocus(self.window?.firstResponder) {
                self.draftFocusInPalette = true
            } else {
                self.finishText()
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let draft = textDraft, control === draft.field, !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            finishText(focusCanvas: true)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finishText(commit: false, focusCanvas: true)
            return true
        }
        return false
    }

    private func finishText(commit: Bool = true, focusCanvas: Bool = false) {
        guard let draft = textDraft else { return }
        let text = draft.text
        textDraft = nil
        stopWatchingDraftClicks()
        draft.field.delegate = nil
        if focusCanvas { window?.makeFirstResponder(canvas) }
        draft.field.removeFromSuperview()
        guard commit, !text.isEmpty, let state = imageState else { syncControls(); return }
        do {
            let annotation = PhotoAnnotation.text(text, anchor: draft.anchor, style: draft.style)
            let layer = try PhotoAnnotationLayer(annotation: annotation, extent: state.pixels.extent, context: context)
            useImageState(ImageState(pixels: state.pixels, display: state.display, annotations: state.annotations + [layer]),
                          actionName: AnnotationTool.text.title)
        } catch {
            syncControls()
            show(error)
        }
    }

    private func transformImage(named actionName: String, _ transform: @escaping (CIImage) throws -> CIImage) {
        updateImage(named: actionName) { state, context in
            let edited = try transform(state.pixels)
            let display = try PhotoCropProcessor.render(edited, context: context, maximumSide: 1800)
            let annotations = try state.annotations.map {
                try $0.transformed(in: state.pixels.extent, context: context, by: transform)
            }
            return ImageState(pixels: edited, display: display, annotations: annotations)
        }
    }

    private func updateImage(named actionName: String, selecting id: UUID? = nil,
                             _ update: @escaping (ImageState, CIContext) throws -> ImageState) {
        guard ready, let imageState, window?.attachedSheet == nil else { return }
        let context = self.context
        busy = true
        syncControls()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try update(imageState, context) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                switch result {
                case let .success(state):
                    self.useImageState(state, actionName: actionName)
                    if let id { self.canvas.selectedAnnotation = id }
                case let .failure(error):
                    self.syncControls()
                    self.show(error)
                }
            }
        }
    }

    private func useImageState(_ state: ImageState, actionName: String) {
        if let old = imageState {
            let isNewEdit = !history.isUndoing && !history.isRedoing
            if isNewEdit { history.beginUndoGrouping() }
            history.registerUndo(withTarget: self) { editor in editor.useImageState(old, actionName: actionName) }
            history.setActionName(actionName)
            if isNewEdit { history.endUndoGrouping() }
        }
        imageState = state
        canvas.image = state.display
        canvas.imageSize = state.pixels.extent.size
        canvas.annotations = state.annotations
        dismissCrop()
        status.stringValue = hasUnsavedChanges
            ? NSLocalizedString("photo-editor-unsaved", value: "Unsaved changes", comment: "")
            : NSLocalizedString("photo-editor-current", value: "Current image", comment: "")
        syncControls()
    }

    @objc func undoCrop(_ sender: Any?) {
        finishText()
        if canUndoCrop { history.undo() }
        showAnnotationProperties()
        syncControls()
    }

    @objc func redoCrop(_ sender: Any?) {
        finishText()
        if canRedoCrop { history.redo() }
        showAnnotationProperties()
        syncControls()
    }

    @objc func saveDocument(_ sender: Any?) {
        save(confirmed: false) { _ in }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        saveAs { _ in }
    }

    private func save(confirmed: Bool, completion: @escaping (Bool) -> Void) {
        finishText()
        guard canSave, let window, window.attachedSheet == nil, let destination else { completion(false); return }
        guard let type = destination.type else { saveAs(completion: completion); return }

        if confirmed || destination.url != sourceURL {
            write(to: destination.url, as: type, replacing: destination.snapshot, completion: completion)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString(
            "photo-editor-confirm-overwrite", value: "Replace “%@” with the edited photo?", comment: ""
        ), destination.url.lastPathComponent)
        alert.addButton(withTitle: NSLocalizedString("photo-editor-replace", value: "Replace", comment: "")).keyEquivalent = ""
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { completion(false); return }
            self.write(to: destination.url, as: type, replacing: destination.snapshot, completion: completion)
        }
    }

    private func saveAs(completion: @escaping (Bool) -> Void) {
        finishText()
        guard canSaveAs, let window, window.attachedSheet == nil else { completion(false); return }
        let panel = NSSavePanel()
        let current = destination?.url ?? sourceURL
        let prefersPNG = current.pathExtension.lowercased() == "png"
        panel.allowedContentTypes = prefersPNG ? [.png, .jpeg] : [.jpeg, .png]
        panel.nameFieldStringValue = current.deletingPathExtension().lastPathComponent + "-edited." + (prefersPNG ? "png" : "jpg")
        panel.directoryURL = current.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let output = panel.url?.standardizedFileURL else { completion(false); return }
            guard output.resolvingSymlinksInPath() != self.sourceURL.resolvingSymlinksInPath(),
                  output.resolvingSymlinksInPath() != current.resolvingSymlinksInPath() else {
                self.show(PhotoCropProcessor.Failure.originalDestination)
                completion(false)
                return
            }
            let snapshot = try? SafeFileReplacement.Item(output)
            if let snapshot, let source = try? SafeFileReplacement.Item(self.sourceURL), snapshot.isSameItem(as: source) {
                self.show(PhotoCropProcessor.Failure.originalDestination)
                completion(false)
                return
            }
            let type: UTType = output.pathExtension.lowercased() == "png" ? .png : .jpeg
            self.write(to: output, as: type, replacing: snapshot, completion: completion)
        }
    }

    private func write(to url: URL, as type: UTType, replacing snapshot: SafeFileReplacement.Item?,
                       completion: @escaping (Bool) -> Void) {
        guard let imageState, !busy else { completion(false); return }
        let context = self.context
        busy = true
        syncControls()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> SafeFileReplacement.Item in
                let image = try PhotoCropProcessor.render(imageState.compositedPixels, context: context)
                return try PhotoCropProcessor.write(image, to: url, as: type, replacing: snapshot)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion(false); return }
                self.busy = false
                switch result {
                case let .success(saved):
                    self.savedRevision = imageState.revision
                    self.destination = Destination(url: url, type: type, snapshot: saved)
                    self.window?.title = url.lastPathComponent
                    self.window?.representedURL = url
                    self.status.stringValue = String(format: NSLocalizedString("photo-editor-saved", value: "Saved %@", comment: ""), url.lastPathComponent)
                    self.syncControls()
                    completion(true)
                case let .failure(error):
                    self.syncControls()
                    self.show(error)
                    completion(false)
                }
            }
        }
    }

    private func confirmChanges(completion: @escaping (Bool) -> Void) {
        guard let window, window.attachedSheet == nil, !busy else { completion(false); return }
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("photo-editor-save-changes", value: "Save changes to “%@”?", comment: ""),
                                        destination?.url.lastPathComponent ?? sourceURL.lastPathComponent)
        alert.addButton(withTitle: NSLocalizedString("photo-editor-save", value: "Save", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: NSLocalizedString("photo-editor-discard", value: "Don't Save", comment: ""))
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                DispatchQueue.main.async { [weak self] in
                    guard let self else { completion(false); return }
                    self.save(confirmed: true, completion: completion)
                }
            case .alertThirdButtonReturn:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    private func show(_ error: Error) {
        status.stringValue = error.localizedDescription
        guard let window, window.isVisible, window.attachedSheet == nil else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }
}

private final class PhotoInlineTextField: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        // Keep the live draft aligned when the field editor is temporarily owned by the style controls.
        guard currentEditor() == nil, let font else {
            super.draw(dirtyRect)
            return
        }
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (backgroundColor ?? .textBackgroundColor).setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.stroke()

        let text = stringValue.isEmpty ? placeholderString ?? "" : stringValue
        let color = stringValue.isEmpty ? NSColor.secondaryLabelColor : textColor ?? .labelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let content = bounds.insetBy(dx: 6, dy: 1)
        let height = text.size(withAttributes: attributes).height
        let line = CGRect(x: content.minX, y: content.midY - height / 2, width: content.width, height: height)
        text.draw(in: line, withAttributes: attributes)
    }
}

private final class PhotoCropCanvas: NSView {
    private enum Drag {
        case marquee, corner(Int), edge(Int), perspectiveHandle(edge: Int, offset: Int), move, newRectangle
    }

    private static let annotationMoveCursor: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        let center = CGPoint(x: 12, y: 12)
        let image = NSImage(size: size, flipped: false) { _ in
            let arrow: [CGPoint] = [
                CGPoint(x: -1.2, y: -5.2), CGPoint(x: -4.2, y: -5.2), CGPoint(x: 0, y: -10),
                CGPoint(x: 4.2, y: -5.2), CGPoint(x: 1.2, y: -5.2), CGPoint(x: 1.2, y: -1.2),
            ]
            let path = NSBezierPath()
            for quarter in 0..<4 {
                let angle = CGFloat(quarter) * .pi / 2
                let cosine = cos(angle), sine = sin(angle)
                for (index, point) in arrow.enumerated() {
                    let vertex = CGPoint(x: center.x + cosine * point.x - sine * point.y,
                                         y: center.y + sine * point.x + cosine * point.y)
                    if quarter == 0 && index == 0 { path.move(to: vertex) }
                    else { path.line(to: vertex) }
                }
            }
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 2.5
            NSColor.white.setStroke()
            path.stroke()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: center)
    }()

    override var isFlipped: Bool { true }
    var mode: PhotoCropMode? {
        didSet {
            drag = nil
            annotationDrag = nil
            if mode != nil { selectedAnnotation = nil }
            needsDisplay = true
            refreshAnnotationCursor()
        }
    }
    var aspect = PhotoCropAspect.free
    var image: CGImage? {
        didSet {
            needsDisplay = true
            refreshAnnotationCursor()
        }
    }
    var imageSize = CGSize.zero
    var selection = PhotoCropSelection() { didSet { needsDisplay = true } }
    var marquee: CGRect? { didSet { needsDisplay = true } }
    var acceptsEditing = false {
        didSet {
            if oldValue != acceptsEditing { refreshAnnotationCursor() }
        }
    }
    var onApply: (() -> Void)?
    weak var floatingPalette: PhotoAnnotationPalette?
    var makeStroke: ((AnnotationTool, CGPoint) -> PhotoAnnotationStroke?)?
    var onStroke: ((AnnotationTool, PhotoAnnotationStroke) -> Void)?
    var onText: ((CGPoint) -> Void)?
    var onMoveAnnotations: (([UUID: PhotoAnnotationLayer]) -> Void)?
    var onDeleteAnnotation: (() -> Void)?
    var onSelectAnnotations: (() -> Void)?
    var onLayout: (() -> Void)?
    var annotations: [PhotoAnnotationLayer] = [] {
        didSet {
            let remaining = selectedAnnotations.intersection(annotations.map(\.id))
            if remaining != selectedAnnotations { selectedAnnotations = remaining }
            needsDisplay = true
            refreshAnnotationCursor()
        }
    }
    var selectedAnnotation: UUID? {
        get { selectedAnnotations.count == 1 ? selectedAnnotations.first : nil }
        set { selectedAnnotations = newValue.map { [$0] } ?? [] }
    }
    var selectedAnnotations: Set<UUID> = [] {
        didSet {
            needsDisplay = true
            if oldValue != selectedAnnotations { onSelectAnnotations?() }
        }
    }
    var annotationTool: AnnotationTool? {
        didSet {
            strokePreview = nil
            drag = nil
            annotationDrag = nil
            needsDisplay = true
            refreshAnnotationCursor()
        }
    }
    private struct AnnotationDrag {
        let layers: [PhotoAnnotationLayer]
        let start: CGPoint
        let bounds: CGRect
        var previews: [UUID: PhotoAnnotationLayer] = [:]
    }
    private var annotationDrag: AnnotationDrag? { didSet { needsDisplay = true } }
    private var strokePreview: PhotoAnnotationStroke? { didSet { needsDisplay = true } }
    private var motionTracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    private var drag: Drag?
    private var start = CGPoint.zero
    private var initial = PhotoCropSelection()

    private var imageFrame: CGRect {
        guard let image else { return .zero }
        let available = bounds.insetBy(dx: 20, dy: 16)
        guard available.width > 0, available.height > 0 else { return .zero }
        let ratio = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
        return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        floatingPalette?.place(in: bounds)
        onLayout?()
        refreshAnnotationCursor()
    }

    func placeTextField(_ field: NSTextField, at anchor: CGPoint, style: PhotoAnnotationTextStyle, input: String) {
        let frame = imageFrame
        guard frame.width > 0, imageSize.width > 0 else { return }
        let size = max(13, min(84, style.size * frame.width / imageSize.width))
        let font = style.fontName.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size, weight: .semibold)
        if field.font != font { field.font = font }
        if let editor = field.currentEditor() as? NSTextView, editor.font != font { editor.font = font }
        let contentWidth = ((input.isEmpty ? field.placeholderString : input) ?? "").size(withAttributes: [.font: font]).width
        let width = min(frame.width, max(126, ceil(contentWidth) + 22))
        let height = min(frame.height, ceil(font.ascender - font.descender) + 12)
        let click = displayPoint(anchor)
        let candidate = CGRect(x: min(click.x, frame.maxX - width), y: min(click.y, frame.maxY - height),
                               width: width, height: height)
        if field.frame != candidate { field.frame = candidate }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        guard let image, !imageFrame.isEmpty else { return }
        let frame = imageFrame
        NSImage(cgImage: image, size: .zero).draw(in: frame, from: .zero, operation: .sourceOver,
                                                   fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        drawAnnotations(in: frame)
        if let tool = annotationTool, tool != .selection {
            if let context = NSGraphicsContext.current?.cgContext {
                strokePreview?.drawPreview(in: context, frame: frame, imageSize: imageSize)
            }
            return
        }
        guard let mode else {
            if let marquee { drawMarquee(marquee) }
            return
        }

        let mesh = mode == .perspective ? selection.perspectiveMesh : nil
        let outline = selectionOutline(mesh: mesh)
        let shade = NSBezierPath(rect: frame)
        shade.append(outline)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        shade.fill()
        NSColor.white.setStroke()
        outline.lineWidth = 1.5
        outline.stroke()
        if let mesh, selection.hasEdgeAdjustments {
            drawGrid(mesh)
        }
        for (i, corner) in selection.corners.map(displayPoint).enumerated() {
            NSColor.white.setFill()
            if let mesh {
                for point in mesh.edgePoints(i).dropFirst().dropLast().map(displayPoint) {
                    let handle = NSBezierPath(rect: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9))
                    handle.fill()
                    NSColor.black.withAlphaComponent(0.7).setStroke()
                    handle.stroke()
                }
            } else {
                let point = displayPoint(edgeMidpoint(i))
                NSBezierPath(ovalIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)).fill()
            }
            let handle = NSBezierPath(roundedRect: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10),
                                      xRadius: 2, yRadius: 2)
            NSColor.controlAccentColor.setFill()
            NSColor.white.setStroke()
            handle.fill()
            handle.lineWidth = 1
            handle.stroke()
        }
    }

    private func canvasRect(for rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX * frame.width / imageSize.width,
               y: frame.maxY - rect.maxY * frame.height / imageSize.height,
               width: rect.width * frame.width / imageSize.width, height: rect.height * frame.height / imageSize.height)
    }

    private func drawAnnotations(in frame: CGRect) {
        guard !annotations.isEmpty, imageSize.width > 0, imageSize.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frame).addClip()
        let outlines = CGMutablePath()
        for existing in annotations {
            let layer = annotationDrag?.previews[existing.id] ?? existing
            let rect = canvasRect(for: layer.bounds, in: frame)
            NSImage(cgImage: layer.preview, size: .zero).draw(in: rect, from: .zero, operation: .sourceOver,
                                                             fraction: 1, respectFlipped: true, hints: nil)
            if mode == nil, selectedAnnotations.contains(layer.id) {
                let placement = CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY)
                outlines.addPath(layer.selectionContour, transform: placement)
            }
        }
        if !outlines.isEmpty, let context = NSGraphicsContext.current?.cgContext {
            context.setLineWidth(1.1)
            context.setStrokeColor(NSColor.white.cgColor)
            context.addPath(outlines)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.setStrokeColor(NSColor.black.cgColor)
            context.addPath(outlines)
            context.strokePath()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func pixelPoint(_ point: CGPoint) -> CGPoint {
        let frame = imageFrame
        return CGPoint(x: (point.x - frame.minX) / frame.width * imageSize.width,
                       y: (frame.maxY - point.y) / frame.height * imageSize.height)
    }

    private func movePreview(to click: CGPoint) {
        guard var drag = annotationDrag else { return }
        let point = pixelPoint(click)
        let extent = CGRect(origin: .zero, size: imageSize)
        let delta = CGPoint(x: min(extent.maxX - drag.bounds.maxX, max(extent.minX - drag.bounds.minX, point.x - drag.start.x)),
                            y: min(extent.maxY - drag.bounds.maxY, max(extent.minY - drag.bounds.minY, point.y - drag.start.y)))
        drag.previews = Dictionary(uniqueKeysWithValues: drag.layers.map { ($0.id, $0.moved(by: delta, in: extent)) })
        annotationDrag = drag
    }

    private func drawMarquee(_ rect: CGRect) {
        let topLeft = displayPoint(rect.origin)
        let bottomRight = displayPoint(CGPoint(x: rect.maxX, y: rect.maxY))
        let border = NSBezierPath(rect: CGRect(x: topLeft.x, y: topLeft.y,
                                               width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y))
        NSColor.black.withAlphaComponent(0.75).setStroke()
        border.lineWidth = 2
        border.stroke()
        NSColor.white.setStroke()
        border.lineWidth = 1
        border.setLineDash([4, 3], count: 2, phase: 0)
        border.stroke()
    }

    private func selectionOutline(mesh: PhotoCropMesh?) -> NSBezierPath {
        let points = (mesh?.boundary ?? selection.corners).map(displayPoint)
        let outline = NSBezierPath()
        outline.move(to: points[0])
        for point in points.dropFirst() { outline.line(to: point) }
        outline.close()
        return outline
    }

    private func drawGrid(_ mesh: PhotoCropMesh) {
        let grid = NSBezierPath()
        for index in 1..<PhotoCropMesh.divisions {
            grid.move(to: displayPoint(mesh.point(row: index, column: 0)))
            for column in 1...PhotoCropMesh.divisions {
                grid.line(to: displayPoint(mesh.point(row: index, column: column)))
            }
            grid.move(to: displayPoint(mesh.point(row: 0, column: index)))
            for row in 1...PhotoCropMesh.divisions {
                grid.line(to: displayPoint(mesh.point(row: row, column: index)))
            }
        }
        NSColor.black.withAlphaComponent(0.32).setStroke()
        grid.lineWidth = 1.5
        grid.stroke()
        NSColor.white.withAlphaComponent(0.46).setStroke()
        grid.lineWidth = 0.5
        grid.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let motionTracking { removeTrackingArea(motionTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        motionTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        if !updateAnnotationCursor(at: event.locationInWindow) { super.mouseEntered(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if !updateAnnotationCursor(at: event.locationInWindow) { super.mouseMoved(with: event) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if !updateAnnotationCursor(at: event.locationInWindow) { super.cursorUpdate(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard event.trackingArea === motionTracking, window?.isKeyWindow == true else { return }
        if NSCursor.current === Self.annotationMoveCursor || NSCursor.current === NSCursor.crosshair {
            NSCursor.arrow.set()
        }
    }

    private func annotation(at point: CGPoint) -> PhotoAnnotationLayer? {
        let frame = imageFrame
        guard mode == nil, imageSize.width > 0, frame.contains(point) else { return nil }
        let pixel = pixelPoint(point)
        let tolerance = 7 * imageSize.width / frame.width
        return annotations.reversed().first { $0.contains(pixel, tolerance: tolerance) }
    }

    private func annotationCursor(at point: CGPoint) -> NSCursor? {
        guard let superview, bounds.contains(point), hitTest(convert(point, to: superview)) === self else { return nil }
        guard acceptsEditing else { return .arrow }
        if annotationDrag != nil { return Self.annotationMoveCursor }
        guard imageFrame.contains(point) else { return .arrow }
        if strokePreview == nil, annotation(at: point) != nil { return Self.annotationMoveCursor }
        return .crosshair
    }

    @discardableResult
    private func updateAnnotationCursor(at windowPoint: CGPoint) -> Bool {
        guard window?.isKeyWindow == true,
              let cursor = annotationCursor(at: convert(windowPoint, from: nil)) else { return false }
        if NSCursor.current !== cursor { cursor.set() }
        return true
    }

    private func refreshAnnotationCursor() {
        if let window { updateAnnotationCursor(at: window.mouseLocationOutsideOfEventStream) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let click = convert(event.locationInWindow, from: nil)
        guard acceptsEditing, let layer = annotation(at: click) else { return super.menu(for: event) }
        window?.makeFirstResponder(self)
        if !selectedAnnotations.contains(layer.id) { selectedAnnotation = layer.id }
        marquee = nil
        let menu = NSMenu()
        let item = menu.addItem(withTitle: PhotoCropWindowController.deleteAnnotationTitle,
                                action: #selector(deleteAnnotationFromMenu(_:)), keyEquivalent: "")
        item.target = self
        return menu
    }

    @objc private func deleteAnnotationFromMenu(_ sender: NSMenuItem) { onDeleteAnnotation?() }

    override func mouseDown(with event: NSEvent) {
        guard acceptsEditing, !imageFrame.isEmpty else { return }
        let click = convert(event.locationInWindow, from: nil)
        if mode == nil, imageFrame.contains(click) {
            if let layer = annotation(at: click) {
                window?.makeFirstResponder(self)
                if !selectedAnnotations.contains(layer.id) { selectedAnnotation = layer.id }
                marquee = nil
                let layers = annotations.filter { selectedAnnotations.contains($0.id) }
                let bounds = layers.compactMap(\.inkBounds).reduce(CGRect.null) { $0.union($1) }
                annotationDrag = AnnotationDrag(layers: layers, start: pixelPoint(click), bounds: bounds)
                updateAnnotationCursor(at: event.locationInWindow)
                return
            }
            selectedAnnotation = nil
        }
        if let tool = annotationTool, tool != .selection {
            guard imageFrame.contains(click) else { return }
            window?.makeFirstResponder(self)
            let point = normalized(click)
            if tool == .text {
                onText?(point)
            } else {
                strokePreview = makeStroke?(tool, point)
            }
            return
        }
        if mode == nil {
            guard imageFrame.contains(click) else { return }
            window?.makeFirstResponder(self)
            start = normalized(click)
            marquee = nil
            drag = .marquee
            return
        }
        guard imageFrame.insetBy(dx: -10, dy: -10).contains(click) else { return }
        start = normalized(click)
        initial = selection
        let mesh = mode == .perspective ? selection.perspectiveMesh : nil
        if let handle = dragHandle(at: click, mesh: mesh) {
            drag = handle
        } else {
            if selectionOutline(mesh: mesh).contains(click) {
                if event.clickCount >= 2 {
                    drag = nil
                    onApply?()
                } else {
                    drag = .move
                }
            } else if mode == .rectangle {
                drag = .newRectangle
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsEditing else { return }
        let click = convert(event.locationInWindow, from: nil)
        if annotationDrag != nil {
            movePreview(to: click)
            Self.annotationMoveCursor.set()
            return
        }
        let point = normalized(click)
        if var stroke = strokePreview {
            stroke.extend(to: point)
            strokePreview = stroke
            return
        }
        guard let drag else { return }
        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        var next = initial
        switch drag {
        case .marquee:
            let rect = PhotoCropSelection.rectangle(from: start, to: point, aspect: .free).bounds
            marquee = rect.width * imageFrame.width >= 3 && rect.height * imageFrame.height >= 3 ? rect : nil
            return
        case .newRectangle:
            next = PhotoCropSelection.rectangle(from: start, to: point, aspect: aspect)
        case .move:
            next.translate(by: delta)
        case let .corner(i):
            if mode == .rectangle {
                next = aspect == .original
                    ? initial.resizingOriginalAspectCorner(i, toward: point)
                    : rectangularAdjustment(i: i, point: point, isCorner: true)
            } else {
                next.corners[i] = point
            }
        case let .edge(i):
            next = aspect == .original
                ? initial.resizingOriginalAspectEdge(i, toward: point)
                : rectangularAdjustment(i: i, point: point, isCorner: false)
        case let .perspectiveHandle(edge, offset):
            guard let anchor = initial.perspectiveMesh?.edgePoints(edge)[offset] else { return }
            next.adjustPerspectiveHandle(edge: edge, offset: offset,
                                         to: CGPoint(x: anchor.x + delta.x, y: anchor.y + delta.y))
        }
        if next.isValid { selection = next }
    }

    override func mouseUp(with event: NSEvent) {
        if acceptsEditing, annotationTool == .selection, case .marquee? = drag, let marquee {
            let extent = CGRect(x: marquee.minX * imageSize.width, y: (1 - marquee.maxY) * imageSize.height,
                                width: marquee.width * imageSize.width, height: marquee.height * imageSize.height)
            self.marquee = nil
            selectedAnnotations = Set(annotations.compactMap { layer in
                guard let ink = layer.inkBounds, extent.contains(ink) else { return nil }
                return layer.id
            })
        }
        drag = nil
        if annotationDrag != nil {
            if acceptsEditing { movePreview(to: convert(event.locationInWindow, from: nil)) }
            let previews = annotationDrag?.previews
            annotationDrag = nil
            if acceptsEditing, let previews { onMoveAnnotations?(previews) }
            updateAnnotationCursor(at: event.locationInWindow)
            return
        }
        guard var stroke = strokePreview else { return }
        strokePreview = nil
        guard acceptsEditing, let tool = annotationTool else { return }
        stroke.extend(to: normalized(convert(event.locationInWindow, from: nil)))
        guard stroke.spans(imageFrame.size, minimum: 3) else { return }
        onStroke?(tool, stroke)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            if acceptsEditing, !selectedAnnotations.isEmpty { onDeleteAnnotation?() }
        } else if acceptsEditing, mode != nil, event.keyCode == 36 || event.keyCode == 76 {
            onApply?()
        } else if acceptsEditing, event.keyCode == 53, marquee != nil || !selectedAnnotations.isEmpty {
            marquee = nil
            selectedAnnotation = nil
            annotationDrag = nil
            drag = nil
        } else {
            super.keyDown(with: event)
        }
    }

    private func rectangularAdjustment(i: Int, point: CGPoint, isCorner: Bool) -> PhotoCropSelection {
        let old = initial.bounds
        var left = old.minX, right = old.maxX, top = old.minY, bottom = old.maxY
        if isCorner ? i == 0 || i == 3 : i == 3 { left = min(point.x, right - 0.01) }
        if isCorner ? i == 1 || i == 2 : i == 1 { right = max(point.x, left + 0.01) }
        if isCorner ? i == 0 || i == 1 : i == 0 { top = min(point.y, bottom - 0.01) }
        if isCorner ? i == 2 || i == 3 : i == 2 { bottom = max(point.y, top + 0.01) }
        return PhotoCropSelection(rect: CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }

    private func edgeMidpoint(_ index: Int) -> CGPoint {
        let start = selection.corners[index]
        let end = selection.corners[(index + 1) % selection.corners.count]
        return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }

    private func dragHandle(at click: CGPoint, mesh: PhotoCropMesh?) -> Drag? {
        var hits: [(handle: Drag, distance: CGFloat)] = []
        for (index, point) in selection.corners.enumerated() {
            let cornerDistance = distance(click, displayPoint(point))
            if cornerDistance <= 11 { hits.append((.corner(index), cornerDistance)) }
            if let mesh {
                let edge = mesh.edgePoints(index)
                for offset in 1..<PhotoCropMesh.divisions {
                    let edgeDistance = distance(click, displayPoint(edge[offset]))
                    if edgeDistance <= 10 { hits.append((.perspectiveHandle(edge: index, offset: offset), edgeDistance)) }
                }
            } else {
                let edgeDistance = distance(click, displayPoint(edgeMidpoint(index)))
                if edgeDistance <= 10 { hits.append((.edge(index), edgeDistance)) }
            }
        }
        return hits.min { $0.distance < $1.distance }?.handle
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func normalized(_ point: CGPoint) -> CGPoint {
        let frame = imageFrame
        return CGPoint(x: min(1, max(0, (point.x - frame.minX) / frame.width)),
                       y: min(1, max(0, (point.y - frame.minY) / frame.height)))
    }

    private func displayPoint(_ point: CGPoint) -> CGPoint {
        let frame = imageFrame
        return CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
    }
}

extension ViewController {
    var photoForEditing: URL? {
        if let review = similarPhotosViewController { return review.selectedEditingURL }
        if publicVar.isInLargeView {
            let file = largeImageView.file
            return file.type == .image ? URL(string: file.path) : nil
        }
        let indexes = collectionView.selectionIndexPaths
        guard indexes.count == 1, let index = indexes.first?.item else { return nil }
        fileDB.lock()
        defer { fileDB.unlock() }
        guard let files = fileDB.db[SortKeyDir(fileDB.curFolder)]?.files, index >= 0, index < files.count else { return nil }
        let file = files.element(atOffset: index).1
        return file.type == .image ? URL(string: file.path) : nil
    }

    func addPhotoEditorItem(to menu: NSMenu, for url: URL) {
        let label = NSLocalizedString("photo-editor-context-edit", value: "Edit", comment: "")
        let item = menu.addItem(withTitle: label, action: #selector(showPhotoEditor(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.image = NSImage(systemSymbolName: PhotoCropWindowController.editorSymbol, accessibilityDescription: label)
    }

    @objc func showPhotoEditor(_ sender: Any?) {
        let url = ((sender as? NSMenuItem)?.representedObject as? URL) ?? photoForEditing
        guard let url, url.isFileURL else { return }
        PhotoCropWindowController.open(url)
    }
}

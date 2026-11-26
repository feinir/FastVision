import Cocoa
import ImageIO
import PDFKit
import UniformTypeIdentifiers

private func inspectorText(_ key: String, _ value: String) -> String {
    NSLocalizedString(key, value: value, comment: "Metadata inspector")
}

struct MetadataInspectorContent {
    struct Annotation {
        let page: String
        let type: String
        let author: String
        let date: String
        let contents: String?
    }

    var title: String
    var overview: [FileInfoSection] = []
    var metadata: [FileInfoSection] = []
    var annotations: [Annotation] = []
    var location: URL?
    var isMultipleSelection = false

    static func load(_ urls: [URL]) -> Self {
        guard urls.count == 1, let url = urls.first else { return loadSelection(urls) }

        let values = try? url.resourceValues(forKeys: [
            .contentTypeKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
            .isDirectoryKey, .isAliasFileKey
        ])
        let title = url.lastPathComponent
        let isDirectory = values?.isDirectory ?? url.hasDirectoryPath
        let resolvedURL = values?.isAliasFile == true ? (try? URL(resolvingAliasFileAt: url)) ?? url : url
        let type = values?.contentType
            ?? (isDirectory ? .folder : UTType(filenameExtension: url.pathExtension, conformingTo: .data))
        var rows = [(NSLocalizedString("Filename", comment: "File name"), title)]
        if let kind = type?.localizedDescription {
            rows.append((inspectorText("inspector-kind", "Kind"), kind))
        }
        if !isDirectory, let size = values?.fileSize {
            rows.append((NSLocalizedString("Exif-FileSize", comment: "File size"), byteCount(size)))
        }
        if let date = values?.creationDate {
            rows.append((NSLocalizedString("Date Created", comment: "Date created"), dateText(date)))
        }
        if let date = values?.contentModificationDate {
            rows.append((NSLocalizedString("Date Modified", comment: "Date modified"), dateText(date)))
        }
        rows.append((NSLocalizedString("File Path", comment: "File path"), url.deletingLastPathComponent().path))
        if resolvedURL != url {
            rows.append((NSLocalizedString("Original Path", comment: "Original path"), resolvedURL.path))
        }

        var content = Self(title: title, overview: [
            section(inspectorText("inspector-file", "File"), rows)
        ])
        guard !isDirectory, !resolvedURL.hasDirectoryPath else { return content }

        let ext = resolvedURL.pathExtension.lowercased()
        if ext == "pdf", let document = PDFDocument(url: resolvedURL) {
            content.overview.append(section(inspectorText("inspector-document", "Document"), [
                (inspectorText("inspector-page-count", "Pages"), document.pageCount.formatted())
            ]))
            if let attributes = document.documentAttributes as? [PDFDocumentAttribute: Any], !attributes.isEmpty {
                let rows = attributes.sorted { $0.key.rawValue < $1.key.rawValue }.map {
                    (fieldName($0.key.rawValue), valueText($0.value))
                }
                content.metadata.append(section(NSLocalizedString("General", comment: "General metadata"), rows))
            }
            content.annotations = (0..<document.pageCount).flatMap { index -> [Annotation] in
                guard let page = document.page(at: index) else { return [] }
                return page.annotations.compactMap { annotation in
                    // A note’s popup repeats the note itself in PDFKit’s annotation list.
                    guard let type = annotation.type, !["Link", "Widget", "Popup"].contains(type) else { return nil }
                    return Annotation(page: page.label ?? (index + 1).formatted(), type: type,
                                      author: annotation.userName ?? "—",
                                      date: annotation.modificationDate.map(dateText) ?? "—",
                                      contents: annotation.contents)
                }
            }
        } else if globalVar.HandledVideoExtensions.contains(ext), isNotFalseTsVideoFile(resolvedURL) {
            if let size = getImageInfo(url: resolvedURL, needMetadata: false)?.size {
                content.overview.append(section(NSLocalizedString("Video", comment: "Video"), [
                    (inspectorText("inspector-pixel-size", "Pixel Size"), pixelSize(size))
                ]))
            }
            if let fields = getVideoMetadataFormatedFFmpeg(for: resolvedURL) {
                content.metadata = ViewController.splitVideoMetadataIntoSections(fields)
            }
        } else if let image = getImageInfo(url: resolvedURL, needMetadata: true) {
            let properties = image.properties ?? [:]
            var imageRows: [(String, String)] = []
            if let size = image.size {
                imageRows.append((inspectorText("inspector-pixel-size", "Pixel Size"), pixelSize(size)))
            }
            let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            if let dpiX = (properties[kCGImagePropertyDPIWidth as String] ?? tiff?[kCGImagePropertyTIFFXResolution as String]) as? NSNumber,
               dpiX.doubleValue > 0 {
                let dpiY = (properties[kCGImagePropertyDPIHeight as String] ?? tiff?[kCGImagePropertyTIFFYResolution as String]) as? NSNumber
                let dpi = dpiY.flatMap { $0.doubleValue == dpiX.doubleValue ? nil : "\(valueText(dpiX)) × \(valueText($0))" }
                    ?? valueText(dpiX)
                imageRows.append((inspectorText("inspector-image-dpi", "Image DPI"), dpi))
            }
            for key in [kCGImagePropertyColorModel, kCGImagePropertyProfileName] {
                if let value = properties[key as String] {
                    imageRows.append((fieldName(key as String), valueText(value)))
                }
            }
            if !imageRows.isEmpty {
                content.overview.append(section(NSLocalizedString("Image", comment: "Image"), imageRows))
            }
            let general = properties.filter { !($0.value is [String: Any]) }
            if !general.isEmpty {
                content.metadata.append(section(NSLocalizedString("General", comment: "General metadata"), metadataRows(general)))
            }
            for key in properties.keys.sorted() {
                guard let group = properties[key] as? [String: Any], !group.isEmpty else { continue }
                let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                content.metadata.append(section(name, metadataRows(group), collapsible: true))
            }
            if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
               let latitude = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
               let longitude = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue {
                let lat = gps[kCGImagePropertyGPSLatitudeRef as String] as? String == "S" ? -latitude : latitude
                let lon = gps[kCGImagePropertyGPSLongitudeRef as String] as? String == "W" ? -longitude : longitude
                content.location = URL(string: "https://maps.apple.com/?q=\(lat),\(lon)")
            }
        }
        return content
    }

    private static func loadSelection(_ urls: [URL]) -> Self {
        var folders = 0
        var totalBytes = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                folders += 1
            } else {
                totalBytes += values?.fileSize ?? 0
            }
        }
        let title = String(format: inspectorText("inspector-selected-count", "%@ selected"), urls.count.formatted())
        return Self(title: title, overview: [section(NSLocalizedString("Statistics", comment: "Selection statistics"), [
            (NSLocalizedString("Files", comment: "Files"), (urls.count - folders).formatted()),
            (NSLocalizedString("Folders", comment: "Folders"), folders.formatted()),
            (NSLocalizedString("Total Size", comment: "Total file size"), byteCount(totalBytes)),
        ])], isMultipleSelection: true)
    }

    private static func section(_ title: String, _ rows: [(String, String)], collapsible: Bool = false) -> FileInfoSection {
        FileInfoSection(title: title, kind: .keyValue(rows), collapsible: collapsible)
    }

    private static func metadataRows(_ values: [String: Any]) -> [(String, String)] {
        values.keys.sorted().compactMap { key in values[key].map { (fieldName(key), valueText($0)) } }
    }

    private static func fieldName(_ field: String) -> String {
        let names = [
            kCGImagePropertyColorModel as String: inspectorText("inspector-color-model", "Color Model"),
            kCGImagePropertyProfileName as String: inspectorText("inspector-color-profile", "Color Profile"),
            kCGImagePropertyPixelWidth as String: inspectorText("inspector-pixel-width", "Pixel Width"),
            kCGImagePropertyPixelHeight as String: inspectorText("inspector-pixel-height", "Pixel Height"),
            kCGImagePropertyDepth as String: NSLocalizedString("Exif-Depth", comment: "Bit depth"),
            kCGImagePropertyExifExposureTime as String: NSLocalizedString("Exif-ExposureTime", comment: "Exposure time"),
            kCGImagePropertyExifDateTimeOriginal as String: NSLocalizedString("Exif-DateTimeOriginal", comment: "Capture time"),
            kCGImagePropertyTIFFMake as String: NSLocalizedString("Exif-CameraMaker", comment: "Camera maker"),
            kCGImagePropertyTIFFModel as String: NSLocalizedString("Exif-CameraModel", comment: "Camera model"),
        ]
        return names[field] ?? field.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }

    private static func valueText(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let date = value as? Date { return dateText(date) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? inspectorText("inspector-yes", "Yes") : inspectorText("inspector-no", "No")
            }
            return number.doubleValue.formatted(.number.precision(.fractionLength(0...6)))
        }
        if let items = value as? [Any] { return items.map(valueText).joined(separator: " · ") }
        if let data = value as? Data { return byteCount(data.count) }
        return String(describing: value)
    }

    private static func pixelSize(_ size: NSSize) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
        return "\(Double(size.width).formatted(format)) × \(Double(size.height).formatted(format))"
    }

    private static func byteCount(_ value: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesActualByteCount = true
        return formatter.string(fromByteCount: Int64(value))
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

final class MetadataInspectorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let heading = NSTextField(labelWithString: "")
    private let tabs = NSSegmentedControl()
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let annotations = NSTableView()
    private let annotationScrollView = NSScrollView()
    private var content: MetadataInspectorContent?
    private var message = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateBackground()

        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabs.segmentCount = 3
        for (index, name) in [
            inspectorText("inspector-file", "File"),
            inspectorText("inspector-details", "Metadata"),
            inspectorText("inspector-annotations", "Annotations")
        ].enumerated() {
            tabs.setLabel(name, forSegment: index)
        }
        tabs.trackingMode = .selectOne
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(switchTab)

        let divider = NSBox()
        divider.boxType = .separator
        let headerSeparator = NSBox()
        headerSeparator.boxType = .separator
        for child in [heading, tabs, divider, headerSeparator, scrollView, annotationScrollView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            divider.leftAnchor.constraint(equalTo: leftAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            headerSeparator.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            headerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
        for scroll in [scrollView, annotationScrollView] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        let document = MetadataInspectorScrollContent()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -14),
        ])
        setUpAnnotations()
        showNoSelection()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    func showNoSelection() {
        content = nil
        setHeading(inspectorText("inspector-title", "File Inspector"))
        message = inspectorText("inspector-no-selection", "Select a file to see its information.")
        render()
    }

    func showLoading(title: String) {
        content = nil
        setHeading(title)
        message = inspectorText("inspector-loading", "Reading file information…")
        render()
    }

    func show(_ content: MetadataInspectorContent) {
        self.content = content
        setHeading(content.title)
        render()
    }

    func containsFocus(_ responder: NSResponder?) -> Bool {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            return field.isDescendant(of: self)
        }
        return (responder as? NSView)?.isDescendant(of: self) ?? false
    }

    private func setHeading(_ title: String) {
        heading.stringValue = title
        heading.toolTip = title
    }

    @objc private func switchTab() { render() }

    private func render() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let showsTable = tabs.selectedSegment == 2 && !(content?.annotations.isEmpty ?? true)
        annotationScrollView.isHidden = !showsTable
        scrollView.isHidden = showsTable
        if showsTable {
            annotations.reloadData()
            annotationScrollView.contentView.scroll(to: .zero)
            annotationScrollView.reflectScrolledClipView(annotationScrollView.contentView)
            return
        }

        if let content {
            switch tabs.selectedSegment {
            case 1:
                if content.metadata.isEmpty {
                    showMessage(content.isMultipleSelection
                        ? inspectorText("inspector-select-one", "Select a single file to see its metadata.")
                        : inspectorText("inspector-no-metadata", "No additional metadata is available."))
                } else {
                    content.metadata.forEach(addSection)
                }
                if content.location != nil {
                    let button = NSButton(title: inspectorText("inspector-open-map", "Show in Maps"),
                                          target: self, action: #selector(openLocation))
                    stack.addArrangedSubview(button)
                }
            case 2:
                showMessage(content.isMultipleSelection
                    ? inspectorText("inspector-select-one-annotations", "Select a single file to see its annotations.")
                    : inspectorText("inspector-no-annotations", "No embedded annotations."))
            default:
                content.overview.forEach(addSection)
            }
        } else {
            showMessage(message)
        }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func addSection(_ section: FileInfoSection) {
        let group = FileInfoSectionView(section: section, compact: true)
        stack.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func showMessage(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @objc private func openLocation() {
        if let url = content?.location { NSWorkspace.shared.open(url) }
    }

    private func setUpAnnotations() {
        annotations.headerView = NSTableHeaderView()
        annotations.usesAlternatingRowBackgroundColors = true
        annotations.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for (key, title, width) in [
            ("page", inspectorText("inspector-page", "Page"), 40.0),
            ("type", inspectorText("inspector-annotation-type", "Type"), 78.0),
            ("author", inspectorText("inspector-annotation-author", "Author"), 62.0),
            ("date", inspectorText("inspector-annotation-date", "Date"), 115.0)
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.minWidth = key == "page" ? 30 : 44
            column.width = width
            annotations.addTableColumn(column)
        }
        annotations.dataSource = self
        annotations.delegate = self
        annotationScrollView.documentView = annotations
    }

    func numberOfRows(in tableView: NSTableView) -> Int { content?.annotations.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let records = content?.annotations, records.indices.contains(row) else { return nil }
        let record = records[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "page": value = record.page
        case "type": value = record.type
        case "author": value = record.author
        default: value = record.date
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = record.contents ?? value
        return field
    }
}

private final class MetadataInspectorScrollContent: NSView {
    override var isFlipped: Bool { true }
}

extension ViewController {
    func setUpMetadataInspector() {
        metadataInspector.translatesAutoresizingMaskIntoConstraints = false
        metadataInspector.isHidden = true
        coreAreaView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metadataInspector, positioned: .above, relativeTo: coreAreaView)

        inspectorClosedConstraint = coreAreaView.rightAnchor.constraint(equalTo: view.rightAnchor)
        inspectorOpenConstraint = coreAreaView.rightAnchor.constraint(equalTo: metadataInspector.leftAnchor)
        let preferredWidth = metadataInspector.widthAnchor.constraint(equalToConstant: 330)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            coreAreaView.leftAnchor.constraint(equalTo: view.leftAnchor),
            coreAreaView.topAnchor.constraint(equalTo: view.topAnchor),
            coreAreaView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            metadataInspector.rightAnchor.constraint(equalTo: view.rightAnchor),
            metadataInspector.topAnchor.constraint(equalTo: view.topAnchor),
            metadataInspector.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            metadataInspector.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.46),
            preferredWidth,
            inspectorClosedConstraint,
        ])
    }

    var isMetadataInspectorVisible: Bool { !metadataInspector.isHidden }

    func toggleMetadataInspector() {
        let isOpening = !isMetadataInspectorVisible
        let oldBounds = largeImageView.bounds
        let imageSize = largeImageView.imageView.frame.size
        let wasFitted = imageSize.width <= oldBounds.width + 1 && imageSize.height <= oldBounds.height + 1 &&
            (abs(imageSize.width - oldBounds.width) <= 1 || abs(imageSize.height - oldBounds.height) <= 1)

        if isOpening {
            inspectorClosedConstraint.isActive = false
            inspectorOpenConstraint.isActive = true
            metadataInspector.isHidden = false
            refreshMetadataInspector(force: true)
        } else {
            if metadataInspector.containsFocus(view.window?.firstResponder) {
                view.window?.makeFirstResponder(collectionView)
            }
            metadataInspector.isHidden = true
            inspectorOpenConstraint.isActive = false
            inspectorClosedConstraint.isActive = true
            cancelMetadataInspectorLoad()
            inspectorURLs = []
            metadataInspector.showNoSelection()
        }
        view.layoutSubtreeIfNeeded()
        if publicVar.isInLargeView {
            if wasFitted && largeImageView.file.type == .image && !largeImageView.isInEditMode && !publicVar.isZoomLocked {
                changeLargeImage(firstShowThumb: false, resetSize: true)
            }
        } else {
            splitViewSizeChanged()
        }
        publicVar.updateToolbar()
    }

    func inspectorContains(_ event: NSEvent) -> Bool {
        isMetadataInspectorVisible && metadataInspector.bounds.contains(metadataInspector.convert(event.locationInWindow, from: nil))
    }

    func requestMetadataInspectorUpdate(force: Bool = false) {
        guard isMetadataInspectorVisible else { return }
        DispatchQueue.main.async { [weak self] in self?.refreshMetadataInspector(force: force) }
    }

    func cancelMetadataInspectorLoad() {
        inspectorRead?.cancel()
        inspectorRead = nil
        inspectorGeneration &+= 1
    }

    private func refreshMetadataInspector(force: Bool) {
        guard isMetadataInspectorVisible, !willTerminate else { return }
        let urls: [URL]
        if publicVar.isInLargeView {
            urls = [URL(string: largeImageView.file.path)].compactMap { $0 }.filter { $0.isFileURL }
        } else {
            urls = collectionView.selectionIndexPaths.sorted { $0.item < $1.item }.compactMap {
                collectionViewManager.file(at: $0).flatMap { URL(string: $0.path) }
            }
        }
        guard force || urls != inspectorURLs else { return }
        cancelMetadataInspectorLoad()
        inspectorURLs = urls
        guard !urls.isEmpty else {
            metadataInspector.showNoSelection()
            return
        }

        let title = urls.count == 1 ? urls[0].lastPathComponent :
            String(format: inspectorText("inspector-selected-count", "%@ selected"), urls.count.formatted())
        metadataInspector.showLoading(title: title)
        let generation = inspectorGeneration
        let work = DispatchWorkItem { [weak self] in
            let content = MetadataInspectorContent.load(urls)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isMetadataInspectorVisible,
                      self.inspectorGeneration == generation else { return }
                self.inspectorRead = nil
                self.metadataInspector.show(content)
            }
        }
        inspectorRead = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}

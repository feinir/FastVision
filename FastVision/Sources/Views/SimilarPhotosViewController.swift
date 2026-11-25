import AppKit

extension ViewController {
    @objc func showSimilarPhotos(_ sender: Any?) {
        guard !publicVar.isInLargeView, publicVar.isKeyEventEnabled, let container = mainScrollView.superview else { return }
        let preferred = ((sender as? NSMenuItem)?.representedObject as? URL)?.standardizedFileURL
        if let review = similarPhotosViewController {
            review.selectPhoto(preferred)
            return
        }

        fileDB.lock()
        let photos = fileDB.db[SortKeyDir(fileDB.curFolder)]?.files.compactMap { entry -> URL? in
            let file = entry.1
            guard file.type == .image, let url = URL(string: file.path), url.isFileURL else { return nil }
            return url.standardizedFileURL
        } ?? []
        fileDB.unlock()

        var seen = Set<URL>()
        let urls = photos.filter { seen.insert($0).inserted }
        guard urls.count >= 2 else {
            coreAreaView.showInfo(NSLocalizedString("similar-photo-minimum", value: "At least two photos are needed.", comment: ""),
                                  timeOut: 2, cannotBeCleard: false)
            return
        }

        stopAutoScroll()
        closeSearchOverlay()
        let review = SimilarPhotosViewController(urls: urls, preferred: preferred)
        review.onClose = { [weak self] in self?.closeSimilarPhotos() }
        review.onTrash = { [weak self] photos in
            EnhancedIndex.handleFilesDeleted(photos.map { $0.url.path })
            guard let self else { return }
            self.publicVar.fileChangedCount += photos.count
            self.scheduledRefresh()
        }
        similarPhotosViewController = review
        addChild(review)
        let content = review.view
        content.translatesAutoresizingMaskIntoConstraints = false
        mainScrollView.isHidden = true
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: globalVar.autoHideToolbar ? -34 : 0),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        (view.window?.windowController as? WindowController)?.updateToolbar()
        review.start()
    }

    func closeSimilarPhotos(restoreFocus: Bool = true) {
        guard let review = similarPhotosViewController else { return }
        similarPhotosViewController = nil
        review.stop()
        review.view.removeFromSuperview()
        review.removeFromParent()
        mainScrollView.isHidden = false
        if restoreFocus { view.window?.makeFirstResponder(collectionView) }
        (view.window?.windowController as? WindowController)?.updateToolbar()
    }
}

final class SimilarPhotosViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSSplitViewDelegate {
    private typealias Photo = SimilarPhotoScanner.Photo

    private enum Row {
        case group(Int)
        case photo(Int, Photo)

        var groupIndex: Int {
            switch self {
            case let .group(index), let .photo(index, _): return index
            }
        }
    }

    var onClose: (() -> Void)?
    var onTrash: ((Set<SimilarPhotoScanner.Photo>) -> Void)?

    private let urls: [URL]
    private let progress: Progress
    private var preferred: URL?
    private var groups: [[Photo]] = []
    private var rows: [Row] = []
    private var marks: [Photo: SimilarPhotoMark] = [:]
    private var unreadableCount = 0
    private var scanFinished = false
    private var trashCount = 0
    private var trashPending = false
    private var progressTimer: Timer?
    private var previewRequest: BlockOperation?
    private var previewedPhoto: Photo?

    private let clearAllButton = NSButton(title: NSLocalizedString("similar-review-clear-all", value: "Clear All Marks", comment: ""),
                                          target: nil, action: nil)
    private let applyButton = NSButton(title: NSLocalizedString("similar-review-apply", value: "Apply", comment: ""),
                                       target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let indicator = NSProgressIndicator()
    private let table = NSTableView()
    private let split = NSSplitView()
    private let preview = NSImageView()
    private let previewHint = NSTextField(wrappingLabelWithString: NSLocalizedString(
        "similar-review-preview", value: "Select a photo to preview it.", comment: ""
    ))
    private let filename = NSTextField(labelWithString: "")
    private let details = NSTextField(labelWithString: "")
    private let filePath = NSTextField(labelWithString: "")
    private let finderButton = NSButton(title: NSLocalizedString("Show in Finder", comment: ""), target: nil, action: nil)
    private let editButton = NSButton(title: NSLocalizedString("photo-editor-open", value: "Edit Photo", comment: ""), target: nil, action: nil)
    private lazy var markButtons = SimilarPhotoMarkAction.allCases.map { action in
        let button = NSButton(title: action.title, target: self, action: #selector(markPhoto(_:)))
        button.tag = action.rawValue
        return button
    }
    private let queue = OperationQueue()
    private let cache = NSCache<NSURL, NSImage>()

    init(urls: [URL], preferred: URL?) {
        self.urls = urls
        self.preferred = preferred
        progress = Progress(totalUnitCount: Int64(urls.count))
        super.init(nibName: nil, bundle: nil)
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 3
        cache.countLimit = 240
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSBox()
        root.boxType = .custom
        root.borderType = .noBorder
        root.fillColor = .windowBackgroundColor
        root.contentViewMargins = .zero
        view = root

        let backLabel = NSLocalizedString("similar-review-back", value: "Back to Browser", comment: "")
        let back = NSButton(image: NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: backLabel) ?? NSImage(),
                            target: self, action: #selector(goBack(_:)))
        back.toolTip = backLabel
        back.setAccessibilityLabel(backLabel)
        clearAllButton.target = self
        clearAllButton.action = #selector(clearAllMarks(_:))
        applyButton.target = self
        applyButton.action = #selector(applyMarks(_:))
        let batchActions = NSStackView(views: [clearAllButton, applyButton])
        batchActions.alignment = .centerY
        batchActions.spacing = 8
        let title = NSTextField(labelWithString: NSLocalizedString("similar-review-title", value: "Similar Photos", comment: ""))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let header = NSStackView(views: [back, title])
        header.spacing = 10
        header.alignment = .centerY

        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        indicator.isIndeterminate = false
        indicator.maxValue = Double(urls.count)
        indicator.controlSize = .small

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("similarPhoto"))
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .regular
        scroll.documentView = table
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(makePreviewPane())
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        let host = root.contentView!
        for item in [header, batchActions, status, indicator, split] {
            item.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            header.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            status.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            status.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            split.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            batchActions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            batchActions.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            indicator.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            indicator.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 12),
            indicator.trailingAnchor.constraint(equalTo: batchActions.leadingAnchor, constant: -12),
            indicator.widthAnchor.constraint(equalToConstant: 100),
        ])
        updateProgress()
        updateSelection()
    }

    private func makePreviewPane() -> NSView {
        let pane = NSView()
        let imageArea = NSView()
        preview.imageScaling = .scaleProportionallyUpOrDown
        previewHint.alignment = .center
        previewHint.textColor = .secondaryLabelColor
        filename.font = .systemFont(ofSize: 14, weight: .semibold)
        details.textColor = .secondaryLabelColor
        filePath.textColor = .secondaryLabelColor
        for label in [filename, details, filePath] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        finderButton.target = self
        finderButton.action = #selector(revealPhoto(_:))
        editButton.target = self
        editButton.action = #selector(editPhoto(_:))
        let markActions = zip(markButtons, SimilarPhotoMarkAction.allCases).map { button, action in
            (button, action.symbol)
        }
        let actions = SimilarPhotoActionRow([(editButton, PhotoCropWindowController.editorSymbol), (finderButton, "folder")] + markActions)
        let metadata = NSStackView(views: [filename, details, filePath, actions])
        metadata.orientation = .vertical
        metadata.alignment = .leading
        metadata.spacing = 6
        metadata.setVisibilityPriority(.detachOnlyIfNecessary, for: filePath)

        for v in [preview, previewHint] {
            v.translatesAutoresizingMaskIntoConstraints = false
            imageArea.addSubview(v)
        }
        for v in [imageArea, metadata] {
            v.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            imageArea.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 14),
            imageArea.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -14),
            imageArea.topAnchor.constraint(equalTo: pane.topAnchor, constant: 12),
            imageArea.bottomAnchor.constraint(equalTo: metadata.topAnchor, constant: -12),
            preview.leadingAnchor.constraint(equalTo: imageArea.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: imageArea.trailingAnchor),
            preview.topAnchor.constraint(equalTo: imageArea.topAnchor),
            preview.bottomAnchor.constraint(equalTo: imageArea.bottomAnchor),
            previewHint.centerYAnchor.constraint(equalTo: imageArea.centerYAnchor),
            previewHint.leadingAnchor.constraint(equalTo: imageArea.leadingAnchor),
            previewHint.trailingAnchor.constraint(equalTo: imageArea.trailingAnchor),
            actions.widthAnchor.constraint(equalTo: metadata.widthAnchor),
            metadata.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 14),
            metadata.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -14),
            metadata.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -12),
        ])
        return pane
    }

    func start() {
        view.window?.makeFirstResponder(table)
        view.superview?.layoutSubtreeIfNeeded()
        split.setPosition(min(300, split.bounds.width * 0.42), ofDividerAt: 0)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
        let urls = self.urls
        let progress = self.progress
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let result = SimilarPhotoScanner.scan(urls, progress: progress) else { return }
            DispatchQueue.main.async { [weak self] in
                guard !progress.isCancelled else { return }
                self?.show(result)
            }
        }
    }

    func stop() {
        progress.cancel()
        progressTimer?.invalidate()
        queue.cancelAllOperations()
    }

    private func updateProgress() {
        let completed = progress.completedUnitCount
        status.stringValue = String(format: NSLocalizedString("similar-photo-progress", value: "Scanning photos… %ld of %ld", comment: ""),
                                    completed, progress.totalUnitCount)
        indicator.doubleValue = Double(completed)
    }

    private func show(_ result: SimilarPhotoScanner.Result) {
        progressTimer?.invalidate()
        progressTimer = nil
        indicator.isHidden = true
        scanFinished = true
        groups = result.groups
        unreadableCount = result.unreadableCount
        reloadRows(selecting: preferred)
        preferred = nil
    }

    private func reloadRows(selecting url: URL? = nil) {
        rows = groups.enumerated().flatMap { index, group in
            [.group(index)] + group.map { .photo(index, $0) }
        }
        table.reloadData()
        if let url, selectPhoto(url) { return }
        if let first = rows.indices.first(where: { photo(at: $0) != nil }) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }
        updateSelection()
    }

    @discardableResult
    func selectPhoto(_ url: URL?) -> Bool {
        guard let url else { return false }
        guard let row = rows.indices.first(where: { photo(at: $0)?.url == url }) else {
            if progressTimer != nil { preferred = url }
            return false
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateSelection()
        return true
    }

    private func photo(at row: Int) -> Photo? {
        guard rows.indices.contains(row), case let .photo(_, photo) = rows[row] else { return nil }
        return photo
    }

    private var selection: Set<Photo> { Set(table.selectedRowIndexes.compactMap { photo(at: $0) }) }
    private var selectedPhoto: Photo? { photo(at: table.selectedRow) }

    private var selectedGroupIndex: Int? {
        let row = table.selectedRow
        return rows.indices.contains(row) ? rows[row].groupIndex : nil
    }

    private var markedForTrash: Set<Photo> {
        Set(marks.compactMap { photo, mark in mark == .trash ? photo : nil })
    }

    var canMarkSelectionForTrash: Bool {
        !trashPending && selection.contains { marks[$0] != .trash }
    }

    private func updateSelection() {
        let photo = selectedPhoto
        let pending = markedForTrash
        finderButton.isEnabled = !trashPending && selection.count == 1
        editButton.isEnabled = finderButton.isEnabled
        for button in markButtons { button.isEnabled = finderButton.isEnabled }
        clearAllButton.isEnabled = !trashPending && !marks.isEmpty
        applyButton.isEnabled = !trashPending && !pending.isEmpty
        if scanFinished { showSummary(pending: pending) }
        guard photo != previewedPhoto else { return }
        previewedPhoto = photo
        previewRequest?.cancel()
        preview.image = nil
        previewHint.stringValue = NSLocalizedString("similar-review-preview", value: "Select a photo to preview it.", comment: "")
        previewHint.isHidden = false
        filename.stringValue = photo?.url.lastPathComponent ?? ""
        filePath.stringValue = photo?.url.deletingLastPathComponent().path ?? ""
        details.stringValue = photo.map { ByteCountFormatter.string(fromByteCount: $0.byteCount, countStyle: .file) } ?? ""
        guard let photo else { return }

        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let image = photo.isCurrent ? SimilarPhotoScanner.thumbnail(at: photo.url, maximumSize: 1280) : nil
            let size = image == nil ? nil : getImageInfo(url: photo.url, needMetadata: false)?.size
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewedPhoto == photo else { return }
                self.preview.image = image.map { NSImage(cgImage: $0, size: .zero) }
                self.previewHint.isHidden = image != nil
                if let size, size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite {
                    self.details.stringValue += "  ·  \(Int(size.width)) × \(Int(size.height))"
                } else if image == nil {
                    self.previewHint.stringValue = NSLocalizedString("similar-photo-missing", value: "This photo is no longer available.", comment: "")
                }
            }
        }
        previewRequest = operation
        queue.addOperation(operation)
    }

    private func showSummary(pending: Set<Photo>) {
        if trashPending {
            status.stringValue = NSLocalizedString("similar-review-trashing", value: "Moving photos to the Trash…", comment: "")
            return
        }
        var parts: [String] = []
        if groups.isEmpty {
            parts.append(NSLocalizedString("similar-photo-no-groups", value: "No similar photos found.", comment: ""))
        } else {
            parts.append(String(format: NSLocalizedString("similar-photo-summary", value: "Groups: %ld · Photos: %ld", comment: ""),
                                groups.count, groups.reduce(0) { $0 + $1.count }))
        }
        if !pending.isEmpty {
            parts.append(String(format: NSLocalizedString("similar-review-pending-count", value: "Marked for removal: %ld", comment: ""),
                                pending.count))
        }
        if trashCount > 0 {
            parts.append(String(format: NSLocalizedString("similar-review-trashed-count", value: "Moved to Trash: %ld", comment: ""), trashCount))
        }
        if unreadableCount > 0 {
            parts.append(String(format: NSLocalizedString("similar-photo-unreadable", value: "Unreadable photos skipped: %ld", comment: ""), unreadableCount))
        }
        status.stringValue = parts.joined(separator: "  ·  ")
        status.toolTip = status.stringValue
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, min(230, splitView.bounds.width * 0.42))
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - min(280, splitView.bounds.width * 0.48))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        photo(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        photo(at: row) == nil ? 26 : 60
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .group(index):
            let group = groups[index]
            let title = String(format: NSLocalizedString("similar-photo-group", value: "Group %ld · Photos: %ld", comment: ""),
                               index + 1, group.count)
            return groupLabel(title, kept: group.filter { marks[$0] == .keep }.count,
                             removed: group.filter { marks[$0] == .trash }.count)
        case let .photo(_, photo):
            let identifier = NSUserInterfaceItemIdentifier("photo")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SimilarPhotoCell) ?? SimilarPhotoCell()
            cell.identifier = identifier
            cell.configure(for: photo.url, mark: marks[photo], queue: queue, cache: cache)
            return cell
        }
    }

    private func groupLabel(_ title: String, kept: Int, removed: Int) -> NSView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        func badge(_ mark: SimilarPhotoMark, count: Int) -> NSStackView {
            let image = NSImageView()
            mark.show(in: image, active: count > 0)
            let number = NSTextField(labelWithString: String(count))
            number.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            number.textColor = image.contentTintColor ?? .secondaryLabelColor
            let badge = NSStackView(views: [image, number])
            badge.alignment = .centerY
            badge.spacing = 3
            badge.toolTip = mark.title
            return badge
        }

        let badges = NSStackView(views: [badge(.keep, count: kept), badge(.trash, count: removed)])
        badges.spacing = 8
        badges.alignment = .centerY
        for item in [label, badges] {
            item.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(item)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badges.leadingAnchor, constant: -6),
            badges.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            badges.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func refreshMarks() {
        let visible = table.rows(in: table.visibleRect)
        if visible.length > 0, let range = Range(visible) {
            table.reloadData(forRowIndexes: IndexSet(integersIn: range), columnIndexes: IndexSet(integer: 0))
        }
        updateSelection()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        let groupIndex = rows[row].groupIndex
        menu.autoenablesItems = false
        if photo(at: row) != nil {
            if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            for button in [editButton, finderButton] + markButtons {
                let item = menu.addItem(withTitle: button.title, action: button.action, keyEquivalent: "")
                item.target = self
                item.tag = button.tag
                item.isEnabled = button.isEnabled
            }
            menu.addItem(.separator())
        }
        let clear = menu.addItem(withTitle: NSLocalizedString("similar-review-clear-group", value: "Clear Group Marks", comment: ""),
                                 action: #selector(clearGroupMarks(_:)), keyEquivalent: "")
        clear.target = self
        clear.representedObject = groupIndex
        clear.isEnabled = !trashPending && groups[groupIndex].contains { marks[$0] != nil }
    }

    @objc private func revealPhoto(_ sender: Any?) {
        guard selection.count == 1, let photo = selectedPhoto, photo.isCurrent else { return }
        NSWorkspace.shared.activateFileViewerSelecting([photo.url])
    }

    var selectedEditingURL: URL? { selection.count == 1 && !trashPending ? selectedPhoto?.url : nil }

    @objc private func editPhoto(_ sender: Any?) {
        guard let url = selectedEditingURL else { return }
        PhotoCropWindowController.open(url)
    }

    @objc private func markPhoto(_ sender: Any?) {
        let tag = (sender as? NSButton)?.tag ?? (sender as? NSMenuItem)?.tag
        guard !trashPending, selection.count == 1, let photo = selectedPhoto,
              let tag, let action = SimilarPhotoMarkAction(rawValue: tag) else { return }
        marks[photo] = action.mark
        if action.marksGroup, let index = selectedGroupIndex {
            let otherMark: SimilarPhotoMark = action.mark == .keep ? .trash : .keep
            for member in groups[index] where member != photo { marks[member] = otherMark }
        }
        refreshMarks()
    }

    @objc func markSelectionForTrash(_ sender: Any?) {
        guard canMarkSelectionForTrash else { return }
        for photo in selection { marks[photo] = .trash }
        refreshMarks()
    }

    @objc private func clearAllMarks(_ sender: Any?) {
        guard !trashPending, !marks.isEmpty else { return }
        marks.removeAll()
        refreshMarks()
    }

    @objc private func clearGroupMarks(_ sender: NSMenuItem) {
        guard !trashPending, let index = sender.representedObject as? Int, groups.indices.contains(index) else { return }
        for photo in groups[index] { marks.removeValue(forKey: photo) }
        refreshMarks()
    }

    @objc private func applyMarks(_ sender: Any?) {
        let pending = markedForTrash
        guard let window = view.window, window.attachedSheet == nil, !pending.isEmpty, !trashPending else { return }
        let marked = groups.flatMap { $0.filter { pending.contains($0) } }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString("similar-review-confirm", value: "Move %ld marked photos to the Trash?", comment: ""),
                                   marked.count)
        alert.informativeText = NSLocalizedString("similar-review-confirm-info", value: "Review the file list before applying.", comment: "")
        alert.accessoryView = trashFileList(marked, windowWidth: window.frame.width)
        alert.addButton(withTitle: NSLocalizedString("Move to Trash", comment: "")).keyEquivalent = ""
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.moveToTrash(marked)
            }
        }
    }

    private func trashFileList(_ photos: [Photo], windowWidth: CGFloat) -> NSScrollView {
        let size = NSSize(width: min(530, max(230, windowWidth - 90)),
                          height: min(245, max(64, CGFloat(photos.count) * 19 + 12)))
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textContainerInset = NSSize(width: 6, height: 5)
        text.isVerticallyResizable = true
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]
        text.setAccessibilityLabel(NSLocalizedString("similar-review-file-list", value: "Files to move to the Trash", comment: ""))
        text.string = photos.enumerated().map { index, photo in
            let path = photo.url.path.replacingOccurrences(of: "\n", with: "\\n")
                                     .replacingOccurrences(of: "\r", with: "\\r")
            return "\(index + 1). \(path)"
        }.joined(separator: "\n")
        scroll.documentView = text
        return scroll
    }

    private func moveToTrash(_ photos: [Photo]) {
        let removing = Set(photos)
        trashPending = true
        updateSelection()
        let groups = self.groups
        let onTrash = self.onTrash
        let selectedURL = selectedPhoto.flatMap { removing.contains($0) ? nil : $0.url }
            ?? selectedGroupIndex.flatMap { groups[$0].first { !removing.contains($0) }?.url }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SimilarPhotoScanner.moveToTrash(photos)
            DispatchQueue.main.async { [weak self] in
                if !result.trashed.isEmpty { onTrash?(result.trashed) }
                guard let self else { return }
                self.trashCount += result.trashed.count
                self.trashPending = false
                for photo in result.trashed { self.marks.removeValue(forKey: photo) }
                self.groups = groups.map { $0.filter { !result.trashed.contains($0) } }.filter { !$0.isEmpty }
                self.reloadRows(selecting: selectedURL)
                if !result.failures.isEmpty, self.view.window != nil {
                    self.status.stringValue = NSLocalizedString("similar-review-trash-failed", value: "Some photos could not be moved to the Trash.", comment: "")
                    self.status.toolTip = result.failures.joined(separator: "\n")
                    showInformationLong(title: self.status.stringValue, message: result.failures.joined(separator: "\n\n"))
                }
            }
        }
    }

    func requestClose() {
        guard !trashPending, let window = view.window, window.attachedSheet == nil else { return }
        let pendingCount = markedForTrash.count
        if pendingCount == 0 {
            onClose?()
            return
        }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("similar-review-discard-title", value: "Discard the pending marks?", comment: "")
        alert.informativeText = String(format: NSLocalizedString("similar-review-discard-info", value: "%ld marked photos are still waiting to be applied.", comment: ""),
                                       pendingCount)
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: NSLocalizedString("similar-review-discard", value: "Discard Marks", comment: "")).keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.onClose?() }
        }
    }

    @objc private func goBack(_ sender: Any?) { requestClose() }
}

private enum SimilarPhotoMarkAction: Int, CaseIterable {
    case keepOnly, keep, trashOnly, trash

    var title: String {
        switch self {
        case .keepOnly: return NSLocalizedString("similar-review-keep-only", value: "Keep Only This Photo", comment: "")
        case .keep: return NSLocalizedString("similar-review-keep", value: "Keep This Photo", comment: "")
        case .trashOnly: return NSLocalizedString("similar-review-trash-only", value: "Remove Only This Photo", comment: "")
        case .trash: return NSLocalizedString("similar-review-trash-photo", value: "Remove This Photo", comment: "")
        }
    }

    var mark: SimilarPhotoMark { self == .keepOnly || self == .keep ? .keep : .trash }
    var marksGroup: Bool { self == .keepOnly || self == .trashOnly }

    var symbol: String {
        let shape = mark == .keep ? "checkmark.circle" : "xmark.circle"
        return marksGroup ? shape + ".fill" : shape
    }
}

private enum SimilarPhotoMark {
    case keep, trash

    var title: String {
        switch self {
        case .keep: return NSLocalizedString("similar-review-marked-keep", value: "Marked to Keep", comment: "")
        case .trash: return NSLocalizedString("similar-review-marked-trash", value: "Marked for Removal", comment: "")
        }
    }

    func show(in view: NSImageView, active: Bool = true) {
        view.image = NSImage(systemSymbolName: self == .keep ? "checkmark.circle" : "xmark.circle",
                             accessibilityDescription: title)
        view.contentTintColor = active ? (self == .keep ? .systemGreen : .systemRed) : .tertiaryLabelColor
        view.toolTip = title
    }
}

private final class SimilarPhotoCell: NSTableCellView {
    private let thumbnail = NSImageView()
    private let markIcon = NSImageView()
    private let filename = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private var thumbnailOperation: BlockOperation?
    private var displayedURL: URL?

    init() {
        super.init(frame: .zero)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        filename.lineBreakMode = .byTruncatingMiddle
        path.lineBreakMode = .byTruncatingHead
        path.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        path.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [filename, path])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        for label in [filename, path] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        for item in [thumbnail, labels, markIcon] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 64),
            thumbnail.heightAnchor.constraint(equalToConstant: 48),
            labels.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: markIcon.leadingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            markIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            markIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            markIcon.widthAnchor.constraint(equalToConstant: 15),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(for url: URL, mark: SimilarPhotoMark?, queue: OperationQueue, cache: NSCache<NSURL, NSImage>) {
        markIcon.isHidden = mark == nil
        mark?.show(in: markIcon)
        thumbnailOperation?.cancel()
        displayedURL = url
        filename.stringValue = url.lastPathComponent
        path.stringValue = url.deletingLastPathComponent().path
        toolTip = url.path
        if let cached = cache.object(forKey: url as NSURL) {
            thumbnail.image = cached
            return
        }
        thumbnail.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false,
                  let preview = SimilarPhotoScanner.thumbnail(at: url, maximumSize: 144),
                  operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self] in
                let image = NSImage(cgImage: preview, size: .zero)
                cache.setObject(image, forKey: url as NSURL)
                guard self?.displayedURL == url else { return }
                self?.thumbnail.image = image
            }
        }
        thumbnailOperation = operation
        queue.addOperation(operation)
    }
}

/// Keeps preview and marking actions in one row as the pane narrows.
private final class SimilarPhotoActionRow: NSView {
    private let buttons: [NSButton]
    private let textWidth: CGFloat
    private let rowHeight: CGFloat
    private var compact = false

    init(_ actions: [(NSButton, String)]) {
        let spacing: CGFloat = 7
        buttons = actions.map { $0.0 }
        for (button, symbol) in actions {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)
            button.imagePosition = .noImage
            button.toolTip = button.title
            button.setAccessibilityLabel(button.title)
        }
        let sizes = buttons.map(\.intrinsicContentSize)
        textWidth = ceil(sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(sizes.count - 1))
        rowHeight = ceil(sizes.map(\.height).max() ?? 0)
        super.init(frame: .zero)

        let row = NSStackView(views: buttons)
        row.spacing = spacing
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rowHeight)
    }

    override func layout() {
        super.layout()
        let needsIcons = bounds.width < textWidth
        guard compact != needsIcons else { return }
        compact = needsIcons
        for button in buttons {
            button.imagePosition = compact ? .imageOnly : .noImage
        }
    }
}

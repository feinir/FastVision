//
//  CustomOutlineViewManager.swift
//  FlowVision
//

import Foundation
import Cocoa

private final class SidebarSectionDivider: NSObject {}

class CustomOutlineViewManager: NSObject {
    var fileDB: DatabaseModel
    var treeViewData: TreeViewModel
    var ifActWhenSelected = true
    weak var outlineView: NSOutlineView?
    
    private var adjustColumnWidthWorkItem: DispatchWorkItem?
    private let locationsDivider = SidebarSectionDivider()
    private let finderTagsDivider = SidebarSectionDivider()
    private static let finderTagsPath = "file:///VirtualFinderTagsFolder/"
    private static let titlePath = "file:///FastVisionTitleFolder/"

    private var rootItems: [NSObject] {
        guard let root = treeViewData.root, let children = root.children else { return [] }
        guard root.fullPath == "root" else { return children }

        var items: [NSObject] = []
        for node in children {
            if node.fullPath == Self.finderTagsPath {
                items.append(finderTagsDivider)
            } else if items.last === treeViewData.favoritesSection {
                items.append(locationsDivider)
            }
            items.append(node)
        }
        return items
    }
    
    init(fileDB: DatabaseModel, treeViewData: TreeViewModel, outlineView: NSOutlineView) {
        self.fileDB = fileDB
        self.treeViewData = treeViewData
        self.outlineView = outlineView
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(favoritesDidChange),
                                               name: GlobalVar.favoritesDidChange, object: nil)
    }

    @objc private func favoritesDidChange() {
        guard let outlineView,
              outlineView.row(forItem: treeViewData.favoritesSection) >= 0 else { return }
        let selectedRow = outlineView.selectedRow
        let selectedItem = selectedRow >= 0 ? outlineView.item(atRow: selectedRow) as? TreeNode : nil
        let wasExpanded = outlineView.isItemExpanded(treeViewData.favoritesSection)
        treeViewData.updateFavorites()

        let wasActingWhenSelected = ifActWhenSelected
        ifActWhenSelected = false
        defer { ifActWhenSelected = wasActingWhenSelected }
        outlineView.reloadItem(treeViewData.favoritesSection, reloadChildren: true)
        if wasExpanded {
            outlineView.expandItem(treeViewData.favoritesSection)
        }
        if let selectedItem {
            let row = outlineView.row(forItem: selectedItem)
            outlineView.selectRowIndexes(row >= 0 ? IndexSet(integer: row) : [], byExtendingSelection: false)
        }
        adjustColumnWidth()
    }
}

extension CustomOutlineViewManager: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rootItems.count }
        return (item as? TreeNode)?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return rootItems[index] }
        return (item as? TreeNode)?.children?[index] ?? ""
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let treeNode = item as? TreeNode else {
            return false
        }
        if treeNode === treeViewData.favoritesSection { return true }
        if (treeNode.children?.count ?? 0) > 0 {
            return true
        }
        if treeNode.hasChild {
            return true
        }
        return false
    }
    func outlineViewItemWillExpand(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? TreeNode {
            // 在这里执行你的代码
            // Execute your code here
            log("TreeData expand: \(item.fullPath)")
            treeViewData.expand(node: item, isLookSub: true)
        }
    }

}
extension CustomOutlineViewManager: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? TreeNode else { return false }
        return node !== treeViewData.favoritesSection
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is SidebarSectionDivider ? 9 : outlineView.rowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let treeNode = item as? TreeNode else { return nil }
        if treeNode.isFavoriteSeparator {
            let identifier = NSUserInterfaceItemIdentifier("SidebarFavoriteSeparator")
            if let view = outlineView.makeView(withIdentifier: identifier, owner: self) {
                return view
            }

            let view = NSTableCellView()
            view.identifier = identifier
            let line = NSBox()
            line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                line.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                line.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            return view
        }
        let view = outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("DataCell"), owner: self) as! CustomTableCellView
        #if APP_STORE
        let displayName = treeNode.localizedName ?? (treeNode.name.hasPrefix("/")
            ? URL(string: treeNode.fullPath)?.lastPathComponent ?? treeNode.name : treeNode.name)
        view.textField?.stringValue = displayName
        #else
        view.textField?.stringValue = treeNode.localizedName ?? treeNode.name
        #endif
        
        view.toolTip = treeNode.isFavorite ? URL(string: treeNode.fullPath).map(GlobalVar.favoriteDisplayPath) : nil

        if treeNode === treeViewData.favoritesSection {
            view.imageView?.image = sidebarSymbol("star", pointSize: 18)
            view.imageView?.contentTintColor = .secondaryLabelColor
        } else if treeNode.fullPath == Self.titlePath {
            view.imageView?.image = NSImage(named: "AppIcon")
            view.imageView?.contentTintColor = nil
        } else if treeNode.fullPath.hasPrefix(Self.finderTagsPath) {
            let tagIcon = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            if let url = URL(string: treeNode.fullPath), url.path != "/VirtualFinderTagsFolder" {
                let tag = FinderTag.byName(url.lastPathComponent)
                if let dotImage = tag?.dotImage {
                    view.imageView?.image = dotImage
                    view.imageView?.contentTintColor = nil
                } else {
                    view.imageView?.image = tagIcon
                    view.imageView?.contentTintColor = .secondaryLabelColor
                }
            } else {
                view.imageView?.image = tagIcon
                view.imageView?.contentTintColor = .secondaryLabelColor
            }
        } else if treeViewData.root?.fullPath == "root", outlineView.parent(forItem: treeNode) == nil {
            #if APP_STORE
            let symbol = URL(string: treeNode.fullPath)?.pathComponents.count == 3 && treeNode.fullPath.hasPrefix("file:///Volumes/")
                ? "internaldrive.fill" : "folder.fill"
            #else
            let symbol = treeNode.name == TreeViewModel.homeRootName ? "house.fill" : "internaldrive.fill"
            #endif
            view.imageView?.image = sidebarSymbol(symbol, pointSize: 16)
            view.imageView?.contentTintColor = .secondaryLabelColor
        } else {
            let folderIcon = NSImage(named: NSImage.folderName)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular))
            view.imageView?.image = folderIcon
            view.imageView?.contentTintColor = nil
        }
        
//        let backgroundView = NSView()
//        backgroundView.wantsLayer = true
//        backgroundView.layer?.backgroundColor = NSColor.lightGray.cgColor
//        view.addSubview(backgroundView, positioned: .below, relativeTo: view.textField)
//
//        // 确保背景视图填充整个cell
//        backgroundView.frame = view.bounds
//        backgroundView.autoresizingMask = [.width, .height]
        
        let isCut = globalVar.cutItemPaths.contains(treeNode.fullPath)
        if isCut {
            view.alphaValue = 0.4
        } else if treeNode.isHidden {
            view.alphaValue = 0.5
        } else {
            view.alphaValue = 1.0
        }
        
        return view
    }

    private func sidebarSymbol(_ name: String, pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView else { return }
        
        let selectedIndex = outlineView.selectedRow
        if selectedIndex != -1, let item = outlineView.item(atRow: selectedIndex) as? TreeNode {
            // 这里调用你的函数，例如:
            // Call your function here, for example:
            itemSelected(item)
        }
    }
    
    func itemSelected(_ item: TreeNode) {
        guard let viewController = getViewController(outlineView) else { return }
        if ifActWhenSelected && item !== treeViewData.favoritesSection && !item.isFavoriteSeparator {
            // log("Selected item: \(item.name)")
            // fileDB.lock()
            // let lastFolderPath = fileDB.curFolder
            // fileDB.curFolder = item.fullPath
            // log(fileDB.curFolder)
            // fileDB.unlock()
            // viewController.publicVar.folderStepStack.insert(lastFolderPath, at: 0)
            viewController.switchDirByDirection(direction: .zero, dest: item.fullPath, doCollapse: false, expandLast: false, skip: false, stackDeep: 0)
        }
        
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard item is SidebarSectionDivider else { return CustomTableRowView() }

        let row = NSTableRowView()
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            line.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }
    
    func outlineViewItemDidExpand(_ notification: Notification) {
        adjustColumnWidth()
        
        // 重新选中之前选中的项
        // Re-select previously selected item
        fileDB.lock()
        let curFolder = fileDB.curFolder
        fileDB.unlock()
        if let item = notification.userInfo?["NSObject"] as? TreeNode,
           let children = item.children {
            for child in children {
                if !child.isFavoriteSeparator && child.fullPath == curFolder {
                    if let row = outlineView?.row(forItem: child),
                       row != -1 {
                        let wasActingWhenSelected = ifActWhenSelected
                        ifActWhenSelected = false
                        outlineView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        ifActWhenSelected = wasActingWhenSelected
                        break
                    }
                }
            }
        }
        
    }
    
    func outlineViewItemDidCollapse(_ notification: Notification) {
        adjustColumnWidth()
    }
    
    func adjustColumnWidth() {
        // 防抖：短时间内多次调用时，只执行最后一次
        // Debounce: when called frequently in a short time, only execute the last one
        adjustColumnWidthWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, let outlineView = self.outlineView else { return }
            
            // 指定你需要调整的列的索引
            // Specify the index of the column you need to adjust
            let columnIndex = 0
            let column = outlineView.tableColumns[columnIndex]
            var maxWidth: CGFloat = 10
            
            // 遍历所有可见行
            // Iterate through all visible rows
            for i in 0..<outlineView.numberOfRows {
                // 获取每行对应列的单元格内容
                // Get cell content for each row's corresponding column
                if let item = outlineView.item(atRow: i) as? TreeNode {
                    // 计算这个单元格内容的宽度
                    // Calculate width of this cell content
                    let content = item.localizedName ?? item.name
                    let attributes = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 13)]
                    let size = (content as NSString).size(withAttributes: attributes)
                    
                    // 获取当前行的层级，并计算缩进
                    // Get current row's level and calculate indentation
                    let level = outlineView.level(forRow: i)
                    let indentation = outlineView.indentationPerLevel * CGFloat(level)
                    
                    // 更新最大宽度
                    // Update maximum width
                    // 再留一点边距
                    // Leave a bit more margin
                    maxWidth = max(maxWidth, size.width + indentation + 35)
                }
            }
            
            column.width = maxWidth
        }
        
        adjustColumnWidthWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }
    
    private func favoriteInsertionIndex(parent: Any?, childIndex: Int) -> Int? {
        guard (parent as? TreeNode) === treeViewData.favoritesSection,
              let children = treeViewData.favoritesSection.children,
              (0...children.count).contains(childIndex) else { return nil }
        if childIndex < children.count { return children[childIndex].favoriteIndex }
        return children.last?.favoriteIndex.map { $0 + 1 } ?? globalVar.myFavoritesArray.count
    }

    private func fileDropTarget(_ item: Any?, childIndex: Int) -> URL? {
        guard childIndex == NSOutlineViewDropOnItemIndex,
              let node = item as? TreeNode, !node.isFavorite,
              node !== treeViewData.favoritesSection,
              node.fullPath != Self.titlePath, !node.fullPath.hasPrefix(Self.finderTagsPath),
              let url = URL(string: node.fullPath), url.isFileURL else { return nil }
        return url
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if info.draggingPasteboard.types?.contains(GlobalVar.favoriteDragType) == true {
            guard (info.draggingSource as? NSOutlineView) === outlineView,
                  globalVar.draggedFavoriteIndex(in: info.draggingPasteboard) != nil,
                  favoriteInsertionIndex(parent: item, childIndex: index) != nil else { return [] }
            return .move
        }
        return fileDropTarget(item, childIndex: index) == nil ? [] : .move
    }
    
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if info.draggingPasteboard.types?.contains(GlobalVar.favoriteDragType) == true {
            guard (info.draggingSource as? NSOutlineView) === outlineView,
                  let source = globalVar.draggedFavoriteIndex(in: info.draggingPasteboard),
                  let insertion = favoriteInsertionIndex(parent: item, childIndex: index) else { return false }
            return globalVar.moveFavorite(from: source, before: insertion)
        }

        guard let targetUrl = fileDropTarget(item, childIndex: index),
              let viewController = getViewController(outlineView) else { return false }

        let pasteboard = info.draggingPasteboard
        if let data = pasteboard.data(forType: .fileURL),
           let pasteboardUrl = URL(dataRepresentation: data, relativeTo: nil),
           pasteboardUrl == targetUrl {
            return false
        }

        if viewController.handleFilePromiseDrop(targetURL: targetUrl, pasteboard: pasteboard) {
            return true
        }

        if info.draggingSource is NSOutlineView,
           let data = pasteboard.data(forType: .fileURL),
           let sourceUrl = URL(dataRepresentation: data, relativeTo: nil) {
            let confirmed = showConfirmation(
                title: NSLocalizedString("Move Items", comment: "移动项目"),
                message: String(format: NSLocalizedString("Are you sure you want to move xxx to xxx?", comment: "确定要移动 xxx 到 xxx?"), sourceUrl.lastPathComponent, targetUrl.lastPathComponent)
            )
            if !confirmed { return false }
        }

        viewController.handleMove(targetURL: targetUrl, pasteboard: pasteboard)
        return true
    }
    
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let outlineItem = item as? TreeNode, outlineItem !== treeViewData.favoritesSection else { return nil }
        if let index = outlineItem.favoriteIndex { return globalVar.favoriteDragItem(at: index) }
        if outlineItem.fullPath == Self.titlePath || outlineItem.fullPath.hasPrefix(Self.finderTagsPath) { return nil }
        
        let pasteboardItem = NSPasteboardItem()

        if let url=URL(string: outlineItem.fullPath) {
            pasteboardItem.setString(url.absoluteString, forType: .fileURL)
        }
        
        return pasteboardItem
    }
    
}

class CustomTableCellView: NSTableCellView {
    
    private var didSetupConstraints = false

    override func awakeFromNib() {
        super.awakeFromNib()

        guard !didSetupConstraints, let imageView = imageView, let textField = textField else { return }
        didSetupConstraints = true

        // 仅在RTL布局时使用Auto Layout约束替换storyboard的固定frame，以支持阿拉伯语等RTL语言的布局镜像
        // Only apply Auto Layout constraints under RTL to mirror the layout for Arabic etc.
        guard userInterfaceLayoutDirection == .rightToLeft else { return }

        imageView.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 3),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    
//    override var backgroundStyle: NSView.BackgroundStyle {
//        didSet {
//            imageView?.contentTintColor = backgroundStyle == .emphasized ? NSColor.black : NSColor.green
//            // 检查是否处于选中状态
//            switch backgroundStyle {
//            case .emphasized: // 选中状态
//                textField?.textColor = NSColor.green
//                // 如果需要，还可以在这里修改imageView的contentTintColor
//            default: // 非选中状态
//                textField?.textColor = NSColor.red
//                // 根据需要恢复imageView的contentTintColor
//            }
//        }
//    }
}

class CustomTableRowView: NSTableRowView {

    override func drawSelection(in dirtyRect: NSRect) {
        if self.selectionHighlightStyle != .none {
            // 边距
            // Margin
            let selectionRect = NSInsetRect(self.bounds, 8, 1.5)
            // 圆角半径
            // Corner radius
            let selectionPath = NSBezierPath(roundedRect: selectionRect, xRadius: 4, yRadius: 4)
            
            // 自定义选中状态下的背景色
            // Customize background color in selected state
            let theme=NSApp.effectiveAppearance.name
            
            // 检查是否是第一响应者
            // Check if is first responder
            if let window = self.window, let firstResponder = window.firstResponder as? NSView, (firstResponder === self || self.isDescendant(of: firstResponder)) {
                if theme == .darkAqua {
                    // 暗模式下的颜色
                    // Color in dark mode
                    NSColor.controlAccentColor.setFill()
                } else {
                    // 光模式下的颜色
                    // Color in light mode
                    NSColor.controlAccentColor.setFill()
                }
            }else{
                NSColor.systemGray.setFill()
            }
            
            selectionPath.fill()
        }
    }

    // 为了更好的视觉效果，可能还需要重写背景色绘制方法
    // For better visual effect, may need to override background color drawing method
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)

        // 自定义非选中状态下的背景色
        // Customize background color in unselected state
        let theme=NSApp.effectiveAppearance.name
        
        if theme == .darkAqua {
            // 暗模式下的颜色
            // Color in dark mode
            // hexToNSColor(hex: "#333333").setFill()
            NSColor(named: NSColor.Name("OutlineViewBgColor"))?.setFill()
        }else {
            // 光模式下的颜色
            // Color in light mode
            // hexToNSColor(hex: "#F4F5F5").setFill()
            NSColor(named: NSColor.Name("OutlineViewBgColor"))?.setFill()
        }

        __NSRectFillUsingOperation(dirtyRect, .sourceOver)
        
        // 边距
        // Margin
        let selectionRect = NSInsetRect(self.bounds, 9, 2.5)
        // 圆角半径
        // Corner radius
        let selectionPath = NSBezierPath(roundedRect: selectionRect, xRadius: 4, yRadius: 4)
        // 获取当前 row 的 index
        // Get current row's index
        if let tableView = self.superview as? NSTableView {
            let rowIndex = tableView.row(for: self)
            if rowIndex == getViewController(self)?.outlineView.curRightClickedIndex {
                // 设置边框颜色
                // Set border color
                NSColor.controlAccentColor.setStroke()
                // 设置边框宽度
                // Set border width
                selectionPath.lineWidth = 2.0
                // 绘制边框
                // Draw border
                selectionPath.stroke()
            }
        }
    }
}

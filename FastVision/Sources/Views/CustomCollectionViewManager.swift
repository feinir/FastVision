//
//  CustomCollectionViewManager.swift
//  FlowVision
//

import Foundation
import Cocoa

class CustomCollectionViewManager: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    
    var fileDB: DatabaseModel
    var lastSelectedIndexPath: IndexPath?
    private var files: [FileModel] = []
    private(set) var presentedItemCount = 0
    
    init(fileDB: DatabaseModel) {
        self.fileDB = fileDB
    }
    
    func replaceFiles(_ files: [FileModel]) {
        self.files = files
        presentedItemCount = 0
        lastSelectedIndexPath = nil
    }

    func presentItems(upTo count: Int) {
        presentedItemCount = min(count, files.count)
    }

    func file(at indexPath: IndexPath) -> FileModel? {
        guard indexPath.section == 0, (0..<presentedItemCount).contains(indexPath.item) else { return nil }
        return files[indexPath.item]
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        section == 0 ? presentedItemCount : 0
    }
    
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "CustomCollectionViewItem"), for: indexPath) as! CustomCollectionViewItem

        let thumbnailView = item.view as! ThumbnailItemView
        if let file = file(at: indexPath), let collectionView = collectionView as? CustomCollectionView {
            thumbnailView.presentationGeneration = collectionView.thumbnailGeneration
            fileDB.lock()
            item.configureWithImage(file)
            fileDB.unlock()
            thumbnailView.isHidden = false
        } else {
            thumbnailView.retire()
        }
        
        return item
    }
    
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard let collectionView = collectionView as? CustomCollectionView,
              let item = item as? CustomCollectionViewItem,
              let thumbnailView = item.view as? ThumbnailItemView,
              thumbnailView.presentationGeneration == collectionView.thumbnailGeneration,
              item.file === file(at: indexPath) else { return }
        thumbnailView.isHidden = false
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        if collectionView.indexPath(for: item) == nil {
            (item.view as? ThumbnailItemView)?.hideThumbnail()
        }
    }
    
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        getViewController(collectionView)?.requestMetadataInspectorUpdate()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        getViewController(collectionView)?.requestMetadataInspectorUpdate()
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        fileDB.lock()
        defer{fileDB.unlock()}
        return file(at: indexPath)?.thumbSize ?? DEFAULT_SIZE
    }
    
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        fileDB.lock()
        defer{fileDB.unlock()}
        let pasteboardItem = NSPasteboardItem()
        if let path = file(at: indexPath)?.path,
           let url = URL(string: path){
            pasteboardItem.setString(url.absoluteString, forType: .fileURL)
        }
        return pasteboardItem
    }
    
    func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        guard let indexPath = indexPaths.first else { return [] }
        
        // Check if the Shift key is pressed or no selection
        if NSEvent.modifierFlags.contains(.shift), let lastIndexPath = lastSelectedIndexPath, collectionView.selectionIndexPaths.count >= 1 {
            // Calculate the range of items to select
            let startIndex = min(lastIndexPath.item, indexPath.item)
            let endIndex = max(lastIndexPath.item, indexPath.item)
            let indexSet = IndexSet(startIndex...endIndex)
            
            // Create new index paths for the range
            let newSelectedIndexPaths = indexSet.map { IndexPath(item: $0, section: indexPath.section) }
            return Set(newSelectedIndexPaths)
        } else {
            // Update the last selected index path for non-shift selection
            lastSelectedIndexPath = indexPath
            return indexPaths
        }
    }
    
    func collectionView(_ collectionView: NSCollectionView, shouldDeselectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        guard let indexPath = indexPaths.first else { return [] }
        
        // TODO
        
        return indexPaths
    }

}


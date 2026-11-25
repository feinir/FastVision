import Darwin
import Foundation

enum SafeFileReplacement {
    struct Failure: LocalizedError {
        let cause: Error
        let recoveryItems: [URL]

        var errorDescription: String? {
            guard !recoveryItems.isEmpty else { return cause.localizedDescription }
            let paths = recoveryItems.map(\.path).joined(separator: "\n")
            return String(format: NSLocalizedString("replacement-recovery", value: "%@\n\nFiles preserved for recovery:\n%@", comment: ""),
                          cause.localizedDescription, paths)
        }
    }

    struct Item {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modified: timespec
        let changed: timespec

        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw posixError(errno, at: url) }
            device = info.st_dev
            inode = info.st_ino
            mode = info.st_mode
            size = info.st_size
            modified = info.st_mtimespec
            changed = info.st_ctimespec
        }

        var isDirectory: Bool { (mode & S_IFMT) == S_IFDIR }
        var isRegularFile: Bool { (mode & S_IFMT) == S_IFREG }

        func isSameItem(as other: Item) -> Bool {
            device == other.device && inode == other.inode
        }

        func isUnchanged(at url: URL) -> Bool {
            guard let current = try? Item(url) else { return false }
            return matches(current, checkingChangeTime: false)
        }

        func matches(_ current: Item, checkingChangeTime: Bool = true) -> Bool {
            isSameItem(as: current) && mode == current.mode && size == current.size
                && modified.tv_sec == current.modified.tv_sec && modified.tv_nsec == current.modified.tv_nsec
                && (!checkingChangeTime || (changed.tv_sec == current.changed.tv_sec && changed.tv_nsec == current.changed.tv_nsec))
        }

        func contains(_ url: URL) -> Bool {
            guard isDirectory else { return false }
            var directory = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            while true {
                if let ancestor = try? Item(directory), isSameItem(as: ancestor) { return true }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path || parent.path.isEmpty { return false }
                directory = parent
            }
        }
    }

    static func isDirectory(at url: URL) -> Bool {
        (try? Item(url))?.isDirectory == true
    }

    static func validateSeparateItems(from source: URL, to destination: URL) throws {
        let sourceItem = try Item(source)
        let destinationItem = try Item(destination)
        guard !sourceItem.isSameItem(as: destinationItem),
              !sourceItem.contains(destination), !destinationItem.contains(source) else {
            throw posixError(EINVAL, at: destination)
        }
    }

    static func replace(from source: URL, to destination: URL, moving: Bool, expecting destinationSnapshot: Item? = nil) throws {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        try validateSeparateItems(from: source, to: destination)
        let originalSource = try Item(source)
        let originalDestination = try Item(destination)
        if let destinationSnapshot, !destinationSnapshot.matches(originalDestination) {
            throw posixError(EBUSY, at: destination)
        }
        let workspace = try makeWorkspace(nextTo: destination)
        let incoming = workspace.appendingPathComponent("incoming")
        let previous = workspace.appendingPathComponent("previous")
        var sourceWorkspace: URL?
        var heldSource: URL?
        var heldDestination: URL?
        var recoveryItems: [URL] = []

        defer {
            for folder in [workspace, sourceWorkspace].compactMap({ $0 }) {
                if !recoveryItems.contains(where: { $0.deletingLastPathComponent().path == folder.path }) {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }

        do {
            let sameVolume = originalSource.device == (try Item(workspace)).device
            if moving && sameVolume {
                try moveWithoutReplacing(source, to: incoming)
                heldSource = incoming
            } else {
                try FileManager.default.copyItem(at: source, to: incoming)
                guard originalSource.isUnchanged(at: source) else { throw posixError(EBUSY, at: source) }
                if moving {
                    let folder = try makeWorkspace(nextTo: source)
                    sourceWorkspace = folder
                    let original = folder.appendingPathComponent(source.lastPathComponent)
                    try moveWithoutReplacing(source, to: original)
                    heldSource = original
                }
            }

            if let heldSource, !originalSource.isUnchanged(at: heldSource) {
                throw posixError(EBUSY, at: source)
            }
            guard originalDestination.isUnchanged(at: destination) else { throw posixError(EBUSY, at: destination) }
            if renamex_np(incoming.path, destination.path, UInt32(RENAME_SWAP)) != 0 {
                let error = errno
                guard supportsFallback(after: error) else { throw posixError(error, at: destination) }
                // Some volumes cannot exchange entries. Keep the old item until the staged item is in place.
                try moveWithoutReplacing(destination, to: previous)
                heldDestination = previous
                guard originalDestination.isUnchanged(at: previous) else { throw posixError(EBUSY, at: destination) }
                try moveWithoutReplacing(incoming, to: destination)
            }
        } catch {
            for (heldItem, original) in [(heldDestination, destination), (heldSource, source)] {
                guard let heldItem else { continue }
                do {
                    try moveWithoutReplacing(heldItem, to: original)
                } catch {
                    recoveryItems.append(heldItem)
                }
            }
            throw Failure(cause: error, recoveryItems: recoveryItems)
        }
    }

    private static func makeWorkspace(nextTo item: URL) throws -> URL {
        let folder = item.deletingLastPathComponent()
            .appendingPathComponent(".fastvision-replace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    private static func moveWithoutReplacing(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) != 0 else { return }
        let error = errno
        guard supportsFallback(after: error) else { throw posixError(error, at: destination) }
        // Every rename is between paths on the same volume.
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private static func supportsFallback(after error: Int32) -> Bool {
        error == ENOTSUP || error == EINVAL || error == ENOSYS
    }

    private static func posixError(_ code: Int32, at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}

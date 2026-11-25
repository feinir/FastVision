#if APP_STORE
import AppKit

/// The browser stores paths internally, so keep each granted scope open while the app is running.
final class SandboxFileAccess {
    static let shared = SandboxFileAccess()
    private let defaults: UserDefaults
    private let key = "browserFolderBookmarks"
    private let lock = NSLock()
    private var folderBookmarks: [String: Data]
    private var folders: [String: URL] = [:]
    private var files: [String: URL] = [:]
    private var activeScopes: [URL] = []

    let documents: URL

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        documents = Self.canonical(appSupport.appendingPathComponent("FastVision/Browser", isDirectory: true),
                                   directory: true)
        try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
        folderBookmarks = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        for (key, data) in Array(folderBookmarks) {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            activeScopes.append(url)
            let folder = Self.canonical(url, directory: true)
            folders[folder.path] = folder
            if (stale || key != folder.path), let bookmark = Self.bookmark(for: url) {
                folderBookmarks.removeValue(forKey: key)
                folderBookmarks[folder.path] = bookmark
            }
        }
        defaults.set(folderBookmarks, forKey: key)
    }

    deinit {
        for url in activeScopes { url.stopAccessingSecurityScopedResource() }
    }

    private static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func canonical(_ url: URL, directory: Bool) -> URL {
        URL(fileURLWithPath: url.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: directory)
    }

    var browsingFolders: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return folders.values.sorted { $0.path < $1.path }
    }

    func canBrowse(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let components = Self.canonical(url, directory: true).pathComponents
        return ([documents] + browsingFolders).contains { folder in
            components.starts(with: folder.pathComponents)
        }
    }

    func explicitlyOpenedFiles(in folder: URL) -> [URL] {
        let path = Self.canonical(folder, directory: true).path
        lock.lock()
        defer { lock.unlock() }
        return files.values.filter { $0.deletingLastPathComponent().path == path }
    }

    /// Call only at OS-mediated entry points such as the open panel, Finder and drag-and-drop.
    func accept(_ url: URL) {
        guard url.isFileURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let canonical = Self.canonical(url, directory: isDirectory)
        if canBrowse(isDirectory ? canonical : canonical.deletingLastPathComponent()) {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if isDirectory {
            guard folders[canonical.path] == nil else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                return
            }
            guard scoped || FileManager.default.isReadableFile(atPath: canonical.path) else { return }
            folders[canonical.path] = canonical
            if let bookmark = Self.bookmark(for: url) {
                folderBookmarks[canonical.path] = bookmark
                defaults.set(folderBookmarks, forKey: key)
            }
        } else {
            guard files[canonical.path] == nil else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                return
            }
            files[canonical.path] = canonical
        }
        if scoped { activeScopes.append(url) }
    }

    @MainActor
    @discardableResult
    func chooseFolder(in suggested: URL? = nil, forSaving: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("store-open-folder", value: "Choose a Folder", comment: "")
        panel.prompt = NSLocalizedString("Open", comment: "")
        if forSaving {
            panel.message = NSLocalizedString("store-save-folder", value: "Choose the destination folder to allow FastVision to save the edited photo safely.", comment: "")
        }
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = suggested
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        accept(url)
        let folder = Self.canonical(url, directory: true)
        return canBrowse(folder) ? folder : nil
    }
}
#endif

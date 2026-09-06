import Foundation

/// Retains the user's chosen Sector Zero library folder across launches.  A
/// sandboxed app may write inside that folder only while its security scope is
/// active, so the bookmark is intentionally kept separate from project data.
@MainActor
final class LibraryFolderAccess {
    private let bookmarkKey = "SectorZero.LibraryFolderBookmark"
    private let userDefaults: UserDefaults
    private(set) var url: URL?

    #if os(macOS)
    private var activeURL: URL?
    #endif

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        restore()
    }

    deinit {
        #if os(macOS)
        activeURL?.stopAccessingSecurityScopedResource()
        #endif
    }

    @discardableResult
    func choose(_ folderURL: URL) -> Bool {
        #if os(macOS)
        do {
            let bookmark = try folderURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            activeURL?.stopAccessingSecurityScopedResource()
            activeURL = folderURL.startAccessingSecurityScopedResource() ? folderURL : nil
            guard activeURL != nil else { return false }
            userDefaults.set(bookmark, forKey: bookmarkKey)
            url = folderURL
            return true
        } catch {
            return false
        }
        #else
        url = folderURL
        return true
        #endif
    }

    private func restore() {
        #if os(macOS)
        guard let bookmark = userDefaults.data(forKey: bookmarkKey) else { return }
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), resolvedURL.startAccessingSecurityScopedResource() else { return }
        activeURL = resolvedURL
        url = resolvedURL
        if isStale { _ = choose(resolvedURL) }
        #endif
    }
}

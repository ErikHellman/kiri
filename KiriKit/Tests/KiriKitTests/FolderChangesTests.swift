import Testing
@testable import KiriKit

@Suite struct FolderChangesTests {
    private let root = "/Users/erik/Sources/tidepool"

    @Test func aFolderInTheRootIsNamedFromTheRoot() {
        #expect(FolderChanges.names(of: root, under: root) == [])
        #expect(FolderChanges.names(of: root + "/", under: root) == [])
        #expect(FolderChanges.names(of: root + "/Sources", under: root) == ["Sources"])
        // FSEvents ends a folder's path with "/".
        #expect(FolderChanges.names(of: root + "/Sources/Tidepool/", under: root) == ["Sources", "Tidepool"])
        #expect(FolderChanges.names(of: root + "/Sources", under: root + "/") == ["Sources"])
    }

    @Test func aFolderOutsideTheRootIsNotInIt() {
        #expect(FolderChanges.names(of: "/Users/erik/Sources", under: root) == nil)
        #expect(FolderChanges.names(of: "/Users/erik/Sources/tidepool-old/Sources", under: root) == nil)
        #expect(FolderChanges.names(of: "/private/var/folders", under: root) == nil)
        #expect(FolderChanges.names(of: "/", under: root) == nil)
    }

    @Test func letterCaseIsNoMatter() {
        #expect(FolderChanges.names(of: "/Users/Erik/sources/Tidepool/Docs", under: root) == ["Docs"])
        // The names below the root are as the disk has them.
        #expect(FolderChanges.names(of: root + "/DOCS/a", under: root) == ["DOCS", "a"])
    }

    @Test func changesInSkippedFoldersLeaveTheIndex() {
        let skipped: Set = [".git", "node_modules", ".build"]
        #expect(FolderChanges.reachesIndex([], skipping: skipped))
        #expect(FolderChanges.reachesIndex(["Sources", "Tidepool"], skipping: skipped))
        #expect(!FolderChanges.reachesIndex([".git"], skipping: skipped))
        #expect(!FolderChanges.reachesIndex([".git", "objects", "4f"], skipping: skipped))
        #expect(!FolderChanges.reachesIndex(["site", "node_modules", "react"], skipping: skipped))
        #expect(FolderChanges.reachesIndex(["git", "build-notes"], skipping: skipped))
    }
}

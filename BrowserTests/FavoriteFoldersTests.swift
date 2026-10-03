import XCTest
@testable import Browser

@MainActor
final class FavoriteFoldersTests: XCTestCase {
    private let chromeExport = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
        <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
        <DL><p>
            <DT><A HREF="https://www.apple.com/">Apple</A>
            <DT><H3>Tech &amp; News</H3>
            <DL><p>
                <DT><A HREF="https://www.macrumors.com/">MacRumors &#8212; caf&#xE9;</A>
                <DT><A HREF="javascript:alert(1)">Bookmarklet</A>
                <DT><H3>Empty</H3>
                <DL><p>
                </DL><p>
            </DL><p>
        </DL><p>
        <DT><H3>Other bookmarks</H3>
        <DL><p>
            <DT><A HREF="https://news.ycombinator.com/item?id=1&amp;p=2">HN</A>
        </DL><p>
    </DL><p>
    """

    private func makeViewModel() -> (BrowserViewModel, () -> Void) {
        let suiteName = "BrowserTests.FavoriteFolders.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (BrowserViewModel(userDefaults: defaults), { defaults.removePersistentDomain(forName: suiteName) })
    }

    func testParserKeepsFoldersAndSkipsNonWebLinksAndEmptyFolders() throws {
        let root = try BookmarkFileParser.parse(chromeExport)

        XCTAssertEqual(root.folders.map(\.title), ["Bookmarks bar", "Other bookmarks"])
        let bar = root.folders[0]
        XCTAssertEqual(bar.links.map(\.title), ["Apple"])
        XCTAssertEqual(bar.folders.map(\.title), ["Tech & News"])
        XCTAssertEqual(bar.folders[0].links.map(\.title), ["MacRumors — café"])
        XCTAssertTrue(bar.folders[0].folders.isEmpty, "Empty folders are dropped")
        XCTAssertEqual(root.folders[1].links.first?.url.absoluteString, "https://news.ycombinator.com/item?id=1&p=2")
        XCTAssertEqual(root.linkCount, 3)
    }

    func testParserRejectsOrdinaryHTML() {
        XCTAssertThrowsError(try BookmarkFileParser.parse("<html><body><a href='https://x.example'>x</a></body></html>"))
    }

    func testImportCreatesOneFolderTreeAndSkipsDuplicatesOnReimport() throws {
        let (viewModel, cleanUp) = makeViewModel()
        defer { cleanUp() }
        let root = try BookmarkFileParser.parse(chromeExport)

        let first = viewModel.importBookmarks(root)
        XCTAssertEqual(first.added, 3)
        XCTAssertEqual(first.folders, 3)
        XCTAssertEqual(first.folderTitle, "Imported Bookmarks")
        XCTAssertEqual(viewModel.favoriteFolders(inFolder: nil).map(\.title), ["Imported Bookmarks"])
        XCTAssertTrue(viewModel.favorites(inFolder: nil).isEmpty)

        let second = viewModel.importBookmarks(root)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.skippedDuplicates, 3)
        XCTAssertEqual(viewModel.favoriteFolders(inFolder: nil).count, 1, "A re-import with nothing new adds no folder")
    }

    func testDeletingFolderRemovesItsSubfoldersAndFavorites() throws {
        let (viewModel, cleanUp) = makeViewModel()
        defer { cleanUp() }
        _ = viewModel.importBookmarks(try BookmarkFileParser.parse(chromeExport))
        let importFolder = try XCTUnwrap(viewModel.favoriteFolders(inFolder: nil).first)
        XCTAssertEqual(viewModel.favoriteCount(inFolderTree: importFolder.id), 3)

        viewModel.deleteFavoriteFolder(importFolder.id)

        XCTAssertTrue(viewModel.favoriteFolders.isEmpty)
        XCTAssertTrue(viewModel.favorites.isEmpty)
    }

    func testFolderCannotMoveIntoItsOwnSubfolder() {
        let (viewModel, cleanUp) = makeViewModel()
        defer { cleanUp() }
        let parent = viewModel.createFavoriteFolder(named: "Parent", in: nil)
        let child = viewModel.createFavoriteFolder(named: "Child", in: parent.id)

        viewModel.moveFavoriteFolder(parent.id, toFolder: child.id)

        XCTAssertNil(viewModel.favoriteFolder(id: parent.id)?.parentID)
        XCTAssertEqual(viewModel.favoriteFolderPath(child.id), "Parent › Child")
    }

    func testRenameFavoriteTrimsAndIgnoresEmptyNames() throws {
        let (viewModel, cleanUp) = makeViewModel()
        defer { cleanUp() }
        _ = viewModel.importBookmarks(try BookmarkFileParser.parse(chromeExport))
        let apple = try XCTUnwrap(viewModel.favorites.first { $0.title == "Apple" })

        viewModel.renameFavorite(apple, to: "  Apple Store  ")
        XCTAssertEqual(viewModel.favorites.first { $0.id == apple.id }?.title, "Apple Store")

        viewModel.renameFavorite(apple, to: "   ")
        XCTAssertEqual(viewModel.favorites.first { $0.id == apple.id }?.title, "Apple Store")
    }
}

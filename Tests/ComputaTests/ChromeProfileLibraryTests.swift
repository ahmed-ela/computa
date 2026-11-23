import Foundation
import SQLite3
import XCTest
@testable import Computa

final class ChromeProfileLibraryTests: XCTestCase {
    @MainActor
    func testImportsVisitWrittenByDisposableChrome() async throws {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard ProcessInfo.processInfo.environment["KOLMOGOR_TEST_DISPOSABLE_CHROME"] == "1",
              FileManager.default.isExecutableFile(atPath: chrome.path) else {
            throw XCTSkip("Opt in with KOLMOGOR_TEST_DISPOSABLE_CHROME=1 to run a separate Chrome profile on localhost")
        }
        let site = try InitialRequestHTTPFixture(finalStatus: 200, finalHTML: "<title>Profile import test visit</title>")
        let url = try await site.start().appendingPathComponent("human/final")
        defer { site.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Chrome")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exit = try await Task.detached {
            let process = Process()
            process.executableURL = chrome
            process.arguments = ["--user-data-dir=" + source.path, "--headless", "--disable-background-networking",
                                 "--disable-sync", "--no-first-run", "--no-default-browser-check", "--dump-dom", url.absoluteString]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ContinuousClock.now + .seconds(30)
            while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate(); process.waitUntilExit(); return Int32(-1) }
            return process.terminationStatus
        }.value
        XCTAssertEqual(exit, 0)
        let profile = try XCTUnwrap(ChromeProfileLibrary.profiles(in: source).first)
        let store = ChromeProfileLibrary(database: root.appendingPathComponent("destination/places.sqlite"))
        XCTAssertGreaterThanOrEqual(try store.importPlaces(from: profile, categories: .init()).history, 1)
        XCTAssertEqual(try store.matches("Profile import test visit").first?.url, url)
    }

    func testSelectedProfileImportsHistorySearchTermsAndNestedBookmarksAcrossReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appendingPathComponent("Chrome")
        let folder = chrome.appendingPathComponent("Profile 2")
        for name in ["Default","Profile 2","Guest Profile"] {
            try FileManager.default.createDirectory(at: chrome.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try #"{"profile":{"name":"Imported fixture"}}"#.write(to: folder.appendingPathComponent("Preferences"), atomically: true, encoding: .utf8)
        let profiles = try ChromeProfileLibrary.profiles(in: chrome)
        XCTAssertEqual(profiles.map(\.name), ["Default","Imported fixture (Profile 2)"])
        let selected = profiles[1]
        let historyFile = folder.appendingPathComponent("History")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(historyFile.path,&db), SQLITE_OK)
        let sql = """
            CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT,hidden INTEGER,last_visit_time INTEGER);
            CREATE TABLE keyword_search_terms(url_id INTEGER,term TEXT);
            INSERT INTO urls VALUES(1,'https://library.example.invalid/item','Visited Page',0,12),
            (2,'https://library.example.invalid/hidden','Hidden Page',1,13),
            (3,'https://library.example.invalid/cb?code=unused&state=unused','Callback Page',0,15);
            INSERT INTO keyword_search_terms VALUES(1,'test search phrase');
            """
        XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK)
        sqlite3_close(db)
        let bookmarks = folder.appendingPathComponent("Bookmarks")
        try #"{"roots":{"bookmark_bar":{"type":"folder","children":[{"type":"folder","name":"Saved research","children":[{"type":"url","url":"https://library.example.invalid/item","name":"Favorite Article"},{"type":"url","url":"https://library.example.invalid/another","name":"Second Favorite"}]}]}}}"#.write(to: bookmarks, atomically: true, encoding: .utf8)
        let store = ChromeProfileLibrary(database: root.appendingPathComponent("destination/places.sqlite"))
        let sourceBytes = try Data(contentsOf: historyFile)
        XCTAssertEqual(try store.importPlaces(from: profiles[0], categories: .init()), .init())
        XCTAssertTrue(try store.matches("library").isEmpty)
        XCTAssertEqual(try store.importPlaces(from: selected, categories: .init(history: true, bookmarks: false)), .init(history: 1))
        XCTAssertTrue(try store.matches("Favorite").isEmpty)
        let searched = try XCTUnwrap(store.matches("test search phrase").first)
        XCTAssertEqual(searched.title, "Visited Page")
        XCTAssertFalse(searched.bookmark)
        for _ in 0..<2 {
            XCTAssertEqual(try store.importPlaces(from: selected, categories: .init()), .init(history: 1, bookmarks: 2))
        }
        let reopened = ChromeProfileLibrary(database: store.database)
        XCTAssertEqual(try reopened.matches("Favorite").map(\.title),["Favorite Article","Second Favorite"])
        XCTAssertEqual(try reopened.matches("test search").first?.bookmark, true)
        XCTAssertEqual(try reopened.matches("Saved research").count, 2)
        XCTAssertTrue(try reopened.matches("hidden").isEmpty)
        XCTAssertTrue(try reopened.matches("Callback").isEmpty)
        XCTAssertTrue(try reopened.matches("%").isEmpty)
        XCTAssertEqual(try Data(contentsOf: historyFile), sourceBytes)
        try "malformed".write(to: bookmarks, atomically: true, encoding: .utf8)
        let other = ChromeProfileLibrary(database: root.appendingPathComponent("other/places.sqlite"))
        XCTAssertThrowsError(try other.importPlaces(from: selected, categories: .init()))
        XCTAssertEqual(try reopened.matches("Favorite").count, 2)
    }
}

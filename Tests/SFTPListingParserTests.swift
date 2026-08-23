import XCTest
@testable import ServerDash

final class SFTPListingParserTests: XCTestCase {
    func testParsesDirectoriesFilesAndSymbolicLinks() {
        let output = """
        Remote working directory: /var/www
        drwxr-xr-x    4 1000     1000         4096 Aug 23 08:00 .
        drwxr-xr-x   12 root     root         4096 Aug 22 18:00 ..
        drwxr-xr-x    2 deploy   deploy       4096 Aug 23 07:10 releases
        -rw-r--r--    1 deploy   deploy      12800 Aug 23 07:20 release notes.txt
        lrwxrwxrwx    1 deploy   deploy          8 Aug 23 07:30 current -> releases
        """

        let listing = SFTPListingParser.parse(output, fallbackPath: ".")

        XCTAssertEqual(listing.path, "/var/www")
        XCTAssertEqual(listing.items.map(\.name), ["releases", "current", "release notes.txt"])
        XCTAssertEqual(listing.items[0].kind, .directory)
        XCTAssertEqual(listing.items[1].kind, .symbolicLink)
        XCTAssertEqual(listing.items[2].size, 12_800)
        XCTAssertEqual(listing.items[2].path, "/var/www/release notes.txt")
    }

    func testRemotePathNavigationStaysAtRoot() {
        XCTAssertEqual(RemotePath.parent(of: "/"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/var/www"), "/var")
        XCTAssertEqual(RemotePath.child("logs", of: "/var"), "/var/logs")
        XCTAssertEqual(RemotePath.normalize("/var/www/../log"), "/var/log")
    }
}

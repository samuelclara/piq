import XCTest
@testable import Piq

final class CopyTests: XCTestCase {
    // Counts use the person's number format, so compare with `Int.formatted()`.

    func testPhotoCountsArePluralized() {
        XCTAssertEqual(Copy.photos(0), "\(0.formatted()) photos")
        XCTAssertEqual(Copy.photos(1), "1 photo")
        XCTAssertEqual(Copy.photos(400), "\(400.formatted()) photos")
    }

    func testLargePhotoCountsAreGrouped() {
        XCTAssertEqual(Copy.photos(1204), "\(1204.formatted()) photos")
    }
}

final class PhotoMetadataTests: XCTestCase {
    private func metadata(filename: String = "IMG_4838.HEIC", date: Date? = nil, width: Int = 4032, height: Int = 3024) -> PhotoMetadata {
        PhotoMetadata(id: "photo", filename: filename, creationDate: date, pixelWidth: width, pixelHeight: height)
    }

    func testAspectRatioIsWidthOverHeight() {
        XCTAssertEqual(metadata(width: 1500, height: 1000).aspectRatio, 1.5, accuracy: 0.0001)
        XCTAssertEqual(metadata(width: 1000, height: 1500).aspectRatio, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testAspectRatioFallsBackToThreeByTwoWhenTheSizeIsUnknown() {
        for (width, height) in [(0, 0), (0, 1000), (1500, 0), (-1, 1000)] {
            XCTAssertEqual(metadata(width: width, height: height).aspectRatio, 1.5, accuracy: 0.0001, "\(width)×\(height)")
        }
    }

    func testChipShowsTheFilenameAndTheCaptureTime() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 14, minute: 32)))

        let chip = metadata(filename: "IMG_4838.HEIC", date: date).chipText

        XCTAssertEqual(chip, "IMG_4838.HEIC \u{00B7} \(date.formatted(date: .omitted, time: .shortened))")
        XCTAssertFalse(chip.contains("2026"), "the time only, no date")
    }

    func testChipIsJustTheFilenameWithoutACaptureDate() {
        XCTAssertEqual(metadata(filename: "IMG_4838.HEIC", date: nil).chipText, "IMG_4838.HEIC")
    }
}

final class LibraryAccessTests: XCTestCase {
    func testOnlyFullAndLimitedAccessCanRead() {
        XCTAssertEqual(LibraryAccess.allCases.filter(\.canRead), [.authorized, .limited])
    }
}

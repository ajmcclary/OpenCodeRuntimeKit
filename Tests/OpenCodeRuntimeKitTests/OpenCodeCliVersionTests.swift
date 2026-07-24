import XCTest
@testable import OpenCodeRuntimeKit

final class OpenCodeCliVersionTests: XCTestCase {
	func testParsesExactThreeComponentVersions() {
		let version = OpenCodeCliVersion(string: "1.18.4")
		XCTAssertEqual(version?.major, 1)
		XCTAssertEqual(version?.minor, 18)
		XCTAssertEqual(version?.patch, 4)
		XCTAssertEqual(version?.description, "1.18.4")
	}

	func testTrimsSurroundingWhitespace() {
		XCTAssertNotNil(OpenCodeCliVersion(string: " 1.17.14\n"))
	}

	func testRejectsMalformedVersions() {
		for bad in ["", "1", "1.18", "1.18.4.2", "v1.18.4", "1.018.4", "1.18.x", "1..4", "-1.2.3", "01.2.3"] {
			XCTAssertNil(OpenCodeCliVersion(string: bad), "Expected rejection for \(bad)")
		}
	}

	func testOrdering() {
		let a = OpenCodeCliVersion(string: "1.17.14")!
		let b = OpenCodeCliVersion(string: "1.18.4")!
		let c = OpenCodeCliVersion(string: "2.0.0")!
		XCTAssertLessThan(a, b)
		XCTAssertLessThan(b, c)
		XCTAssertFalse(b < b)
	}

	func testRangeContainsInclusiveBounds() {
		let range = OpenCodeCliVersionRange(
			lowerBound: OpenCodeCliVersion(string: "1.17.14")!,
			upperBound: OpenCodeCliVersion(string: "1.18.4")!
		)!
		XCTAssertTrue(range.contains(OpenCodeCliVersion(string: "1.17.14")!))
		XCTAssertTrue(range.contains(OpenCodeCliVersion(string: "1.18.4")!))
		XCTAssertTrue(range.contains(OpenCodeCliVersion(string: "1.18.0")!))
		XCTAssertFalse(range.contains(OpenCodeCliVersion(string: "1.18.5")!))
	}

	func testInvertedRangeRejected() {
		XCTAssertNil(OpenCodeCliVersionRange(
			lowerBound: OpenCodeCliVersion(string: "1.18.4")!,
			upperBound: OpenCodeCliVersion(string: "1.17.14")!
		))
	}
}

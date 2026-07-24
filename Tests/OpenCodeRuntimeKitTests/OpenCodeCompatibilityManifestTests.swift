import XCTest
@testable import OpenCodeRuntimeKit

final class OpenCodeCompatibilityManifestTests: XCTestCase {
	private let sha = String(repeating: "9a", count: 32)
	private let otherSHA = String(repeating: "1b", count: 32)

	private func manifestJSON(
		families: String = "[]",
		knownBad: String = "[]",
		schemaVersion: Int = 1
	) -> Data {
		Data("""
		{
			"schemaVersion": \(schemaVersion),
			"manifestVersion": "2026-07-22.1",
			"families": \(families),
			"knownBad": \(knownBad)
		}
		""".utf8)
	}

	private var validFamilyJSON: String {
		"""
		[{
			"id": "stable-1.18",
			"classification": "supported",
			"minCliVersion": "1.17.14",
			"maxCliVersion": "1.18.4",
			"sessionCapabilities": {"loadSession": true, "listSessions": true, "resumeSession": true, "closeSession": true},
			"certifiedRows": [{
				"sha256": "\(sha)",
				"cliVersion": "1.18.4",
				"architecture": "arm64",
				"launchProfileKey": "\(otherSHA)",
				"contractKey": "\(otherSHA)",
				"acceptanceID": "acceptance-1.18.4",
				"provenance": "installed-binary",
				"limitations": []
			}]
		}]
		"""
	}

	func testDecodesValidManifest() throws {
		let manifest = try OpenCodeCompatibilityManifest.decode(from: manifestJSON(families: validFamilyJSON))
		XCTAssertEqual(manifest.manifestVersion, "2026-07-22.1")
		XCTAssertEqual(manifest.families.count, 1)
		XCTAssertEqual(manifest.families.first?.certifiedRows.count, 1)
		XCTAssertEqual(manifest.families.first?.certifiedRows.first?.provenance, .installedBinary)
	}

	func testRejectsUnexpectedRootProperty() {
		let data = Data("""
		{"schemaVersion": 1, "manifestVersion": "x", "families": [], "knownBad": [], "extra": true}
		""".utf8)
		XCTAssertThrowsError(try OpenCodeCompatibilityManifest.decode(from: data)) { error in
			XCTAssertEqual(error as? OpenCodeManifestDecodingError, .unexpectedProperty("extra"))
		}
	}

	func testRejectsUnexpectedSchemaVersion() {
		XCTAssertThrowsError(try OpenCodeCompatibilityManifest.decode(from: manifestJSON(schemaVersion: 2))) { error in
			XCTAssertEqual(error as? OpenCodeManifestDecodingError, .unexpectedSchemaVersion(2))
		}
	}

	func testRejectsMalformedHash() {
		let families = validFamilyJSON.replacingOccurrences(of: sha, with: "nothex")
		XCTAssertThrowsError(try OpenCodeCompatibilityManifest.decode(from: manifestJSON(families: families)))
	}

	func testRejectsInvertedVersionRange() {
		let families = validFamilyJSON
			.replacingOccurrences(of: "\"minCliVersion\": \"1.17.14\"", with: "\"minCliVersion\": \"1.19.0\"")
		XCTAssertThrowsError(try OpenCodeCompatibilityManifest.decode(from: manifestJSON(families: families))) { error in
			XCTAssertEqual(error as? OpenCodeManifestDecodingError, .invertedVersionRange("stable-1.18"))
		}
	}

	func testRejectsDuplicateCertifiedIdentityAcrossFamilies() {
		let families = "[\(validFamilyJSON.dropFirst().dropLast()), \(validFamilyJSON.dropFirst().dropLast().replacingOccurrences(of: "stable-1.18", with: "stable-dup"))]"
		XCTAssertThrowsError(try OpenCodeCompatibilityManifest.decode(from: manifestJSON(families: families))) { error in
			guard case .duplicateCertifiedIdentity = error as? OpenCodeManifestDecodingError else {
				return XCTFail("expected duplicateCertifiedIdentity, got \(error)")
			}
		}
	}

	func testKnownBadRequiresExactlyOneAxis() {
		let zeroAxes = "[{\"reason\": \"broken\"}]"
		XCTAssertThrowsError(try OpenCodeCompatibilityManifest.decode(from: manifestJSON(knownBad: zeroAxes))) { error in
			XCTAssertEqual(error as? OpenCodeManifestDecodingError, .knownBadMatchAxisCount(0))
		}

		let twoAxes = "[{\"reason\": \"broken\", \"sha256\": \"\(sha)\", \"contractKey\": \"\(otherSHA)\"}]"
		XCTAssertThrowsError(try OpenCodeCompatibilityManifest.decode(from: manifestJSON(knownBad: twoAxes))) { error in
			XCTAssertEqual(error as? OpenCodeManifestDecodingError, .knownBadMatchAxisCount(2))
		}
	}

	func testDecodesKnownBadVersionRangeAxis() throws {
		let knownBad = "[{\"reason\": \"regressed acp\", \"minCliVersion\": \"1.18.0\", \"maxCliVersion\": \"1.18.1\"}]"
		let manifest = try OpenCodeCompatibilityManifest.decode(from: manifestJSON(knownBad: knownBad))
		guard case .cliVersionRange(let range)? = manifest.knownBadRules.first?.match else {
			return XCTFail("expected version-range axis")
		}
		XCTAssertTrue(range.contains(OpenCodeCliVersion(string: "1.18.0")!))
	}

	func testRejectsInvalidProvenance() {
		let families = validFamilyJSON.replacingOccurrences(of: "installed-binary", with: "totally-real")
		XCTAssertThrowsError(try OpenCodeCompatibilityManifest.decode(from: manifestJSON(families: families))) { error in
			XCTAssertEqual(error as? OpenCodeManifestDecodingError, .invalidEnum("totally-real"))
		}
	}

	func testEmptyManifestFallbackIsConservative() {
		XCTAssertTrue(OpenCodeCompatibilityManifest.empty.families.isEmpty)
		XCTAssertTrue(OpenCodeCompatibilityManifest.empty.knownBadRules.isEmpty)
	}
}

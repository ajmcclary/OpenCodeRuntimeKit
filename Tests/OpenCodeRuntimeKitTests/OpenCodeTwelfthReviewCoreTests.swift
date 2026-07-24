import XCTest
@testable import OpenCodeRuntimeKit

/// Twelfth acceptance-remediation round (2026-07-23), core-package half:
/// - finding 7: the semantic usage/window domain applies at EVERY projection boundary —
///   `OpenCodeUsageSnapshot.decode` and `sanitizedUsagePayload` still admitted an exact
///   `used = Int.max` / `size = Int.max` via `nonNegativeCount`, so a hostile
///   `usage_update` survived accumulation and was published as exact session usage.
final class OpenCodeTwelfthReviewCoreTests: XCTestCase {
	private func parsedObject(_ json: String) throws -> [String: Any] {
		try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
	}

	// MARK: - Finding 7: usage_update domain bound at snapshot decode

	/// A `usage_update` carrying `used = Int.max, size = Int.max` decodes to UNKNOWN
	/// context fields — never to a fabricated exact reading — while the hostile raw
	/// payload stays visible in provenance.
	func testHostileUsedAndSizeDecodeToUnknownNotExactReadings() throws {
		let object = try parsedObject(
			#"{"used":9223372036854775807,"size":9223372036854775807,"cost":0.25}"#
		)
		let snapshot = OpenCodeUsageSnapshot.decode(usageObject: object, source: .usageUpdate)
		XCTAssertNil(snapshot.contextUsedTokens, "an out-of-domain `used` is unknown, never a reading")
		XCTAssertNil(snapshot.contextWindowTokens, "an out-of-domain `size` is unknown, never a window")
		XCTAssertEqual(snapshot.costAmount, 0.25, "legitimate in-domain fields still survive")
		let provenance = try XCTUnwrap(snapshot.rawProvenanceJSON)
		XCTAssertTrue(
			provenance.contains("9223372036854775807"),
			"the rejected value remains visible ONLY as provenance evidence"
		)
	}

	/// Every decoded count field is domain-bounded, not just used/size.
	func testAllHostileCountFieldsDecodeToUnknown() throws {
		let object = try parsedObject(
			#"{"inputTokens":9223372036854775807,"outputTokens":2000000000000,"reasoningTokens":1000000000001,"cachedReadTokens":9223372036854775807,"cachedWriteTokens":1000000000001}"#
		)
		let snapshot = OpenCodeUsageSnapshot.decode(usageObject: object, source: .promptResponse)
		XCTAssertNil(snapshot.inputTokens)
		XCTAssertNil(snapshot.outputTokens)
		XCTAssertNil(snapshot.reasoningTokens)
		XCTAssertNil(snapshot.cacheReadTokens)
		XCTAssertNil(snapshot.cacheWriteTokens)
	}

	/// In-domain values are untouched — the bound is a domain check, not a rejection of
	/// large-but-plausible sessions.
	func testInDomainUsageDecodeIsUnchanged() throws {
		let object = try parsedObject(
			#"{"used":123456,"size":200000,"inputTokens":1000000000000,"outputTokens":42}"#
		)
		let snapshot = OpenCodeUsageSnapshot.decode(usageObject: object, source: .usageUpdate)
		XCTAssertEqual(snapshot.contextUsedTokens, 123_456)
		XCTAssertEqual(snapshot.contextWindowTokens, 200_000)
		XCTAssertEqual(snapshot.inputTokens, 1_000_000_000_000, "the domain boundary itself is in-domain")
		XCTAssertEqual(snapshot.outputTokens, 42)
	}

	/// A snapshot accumulated from a hostile update followed by a legitimate one keeps
	/// the legitimate reading: unknown never overwrites known, and the hostile value
	/// never becomes known in the first place.
	func testMergePreservesLegitimateReadingAcrossHostileUpdate() throws {
		let legitimate = OpenCodeUsageSnapshot.decode(
			usageObject: try parsedObject(#"{"used":1234,"size":200000}"#),
			source: .usageUpdate
		)
		let hostile = OpenCodeUsageSnapshot.decode(
			usageObject: try parsedObject(#"{"used":9223372036854775807}"#),
			source: .usageUpdate
		)
		let merged = legitimate.merging(latest: hostile)
		XCTAssertEqual(merged.contextUsedTokens, 1234, "the hostile update contributes nothing")
		XCTAssertEqual(merged.contextWindowTokens, 200_000)
	}

	// MARK: - Finding 7: sanitized forwarded payload

	/// `sanitizedUsagePayload` must strip an exact-but-out-of-domain count so no less
	/// careful downstream parser can re-read it from the forwarded payload.
	func testSanitizedPayloadStripsOutOfDomainCounts() throws {
		let payload = try parsedObject(
			#"{"used":9223372036854775807,"size":1000000000001,"inputTokens":7,"cost":0.5,"unrelated":"kept"}"#
		)
		let sanitized = OpenCodeJSONNumberPolicy.sanitizedUsagePayload(payload)
		XCTAssertNil(sanitized["used"], "Int.max `used` must not ride the forwarded payload")
		XCTAssertNil(sanitized["size"], "an out-of-domain `size` must not ride the forwarded payload")
		XCTAssertEqual(sanitized["inputTokens"] as? Int, 7, "in-domain counts survive")
		XCTAssertEqual(sanitized["cost"] as? Double, 0.5)
		XCTAssertEqual(sanitized["unrelated"] as? String, "kept", "non-usage fields are untouched")
	}

	/// The domain boundary value itself survives sanitization (exact bound, not off-by-one).
	func testSanitizedPayloadKeepsDomainBoundaryValue() throws {
		let payload = try parsedObject(#"{"used":1000000000000}"#)
		let sanitized = OpenCodeJSONNumberPolicy.sanitizedUsagePayload(payload)
		XCTAssertEqual(sanitized["used"] as? Int, 1_000_000_000_000)
	}
}

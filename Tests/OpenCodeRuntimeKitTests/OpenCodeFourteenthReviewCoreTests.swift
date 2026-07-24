import XCTest
@testable import OpenCodeRuntimeKit

/// Fourteenth (final) acceptance-remediation round (2026-07-23), core-package half:
/// - finding 3: `costCurrency` is a provider-controlled scalar that bypassed every byte
///   bound — `decode` stored `costObject["currency"] as? String` unbounded, the value
///   survived `merging(latest:)` and reached the finalized-session evidence cache. It now
///   has a documented conservative policy (≤ 16 UTF-8 bytes, ≤ 8 scalars, only
///   letters/digits/currency-symbol scalars) enforced at the DESIGNATED initializer, so
///   no construction path — decode, merge, or direct init — can retain an out-of-policy
///   value. Rejected values stay visible only through the already-bounded provenance
///   preview + digest.
final class OpenCodeFourteenthReviewCoreTests: XCTestCase {
	private func parsedObject(_ json: String) throws -> [String: Any] {
		try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
	}

	private func decodeWithCurrency(_ currencyJSONFragment: String) throws -> OpenCodeUsageSnapshot {
		let object = try parsedObject("{\"used\":100,\"cost\":{\"amount\":0.25,\"currency\":\(currencyJSONFragment)}}")
		return OpenCodeUsageSnapshot.decode(usageObject: object, source: .usageUpdate)
	}

	// MARK: - Ordinary identifiers survive

	func testOrdinaryCurrencyIdentifiersSurviveDecode() throws {
		for valid in ["USD", "usd", "EUR", "BTC", "$", "€", "credits"] {
			let snapshot = try decodeWithCurrency("\"\(valid)\"")
			XCTAssertEqual(snapshot.costCurrency, valid, "a legitimate currency identifier must survive: \(valid)")
			XCTAssertEqual(snapshot.costAmount, 0.25)
		}
	}

	// MARK: - Oversized values are not retained

	func testOversizedCurrencyIsNotRetainedAnywhereOnTheSnapshot() throws {
		let oversized = String(repeating: "A", count: 1_000_000)
		let snapshot = try decodeWithCurrency("\"\(oversized)\"")
		XCTAssertNil(snapshot.costCurrency, "a megabyte 'currency' is not a currency identifier")
		XCTAssertEqual(snapshot.costAmount, 0.25, "the numeric cost is independent evidence and survives")
		XCTAssertEqual(snapshot.contextUsedTokens, 100)
		// The rejected value must be represented ONLY by the bounded provenance evidence.
		for entry in snapshot.provenanceTrail {
			XCTAssertLessThanOrEqual(
				entry.rawJSON?.utf8.count ?? 0, OpenCodeUsageSnapshot.maxProvenanceEntryPreviewBytes,
				"provenance previews stay within the per-entry byte bound"
			)
			XCTAssertNotEqual(entry.rawJSON, oversized, "no retained string may be the original oversized value")
		}
		XCTAssertLessThanOrEqual(snapshot.retainedProvenanceByteCount, OpenCodeUsageSnapshot.maxRetainedProvenanceBytes)
	}

	/// A value just over the byte bound is rejected; one at the bound (all-ASCII letters)
	/// is inside the documented policy.
	func testCurrencyByteBoundIsExact() throws {
		let atBound = String(repeating: "X", count: 16)
		XCTAssertEqual(try decodeWithCurrency("\"\(atBound)\"").costCurrency, nil, "16 letters exceed the 8-scalar bound")
		let eightLetters = "ABCDEFGH"
		XCTAssertEqual(try decodeWithCurrency("\"\(eightLetters)\"").costCurrency, eightLetters, "8 scalars / 8 bytes is within policy")
		let nineLetters = "ABCDEFGHI"
		XCTAssertNil(try decodeWithCurrency("\"\(nineLetters)\"").costCurrency, "9 scalars exceed the scalar bound")
	}

	// MARK: - Control / malformed values are not retained

	func testControlAndMalformedCurrencyValuesAreNotRetained() throws {
		let malformed: [String] = [
			"US\u{0000}D",          // NUL control
			"U\nSD",                 // newline control
			"US D",                  // whitespace
			"USD;rm",                // punctuation
			"\u{202E}DSU",           // bidi override (Cf format control)
			"\u{0007}",              // BEL
			"",                      // empty
			"   ",                   // whitespace-only
		]
		for value in malformed {
			let encoded = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: [value]), encoding: .utf8))
			// Strip the array brackets to reuse the fragment helper.
			let fragment = String(encoded.dropFirst().dropLast())
			let snapshot = try decodeWithCurrency(fragment)
			XCTAssertNil(snapshot.costCurrency, "a control/malformed value is not a currency identifier: \(value.debugDescription)")
		}
	}

	/// A non-string currency (object/number/bool) stays unknown rather than crashing or
	/// being coerced.
	func testNonStringCurrencyStaysUnknown() throws {
		for fragment in ["123", "true", "{\"nested\":\"USD\"}", "[\"USD\"]", "null"] {
			let snapshot = try decodeWithCurrency(fragment)
			XCTAssertNil(snapshot.costCurrency, "a non-string currency is unknown: \(fragment)")
		}
	}

	// MARK: - Merging / repeated finalization cannot reintroduce an oversized value

	func testMergingCannotReintroduceOversizedCurrency() throws {
		let valid = try decodeWithCurrency("\"USD\"")
		let oversized = String(repeating: "B", count: 500_000)
		let hostile = try decodeWithCurrency("\"\(oversized)\"")

		// Later hostile over earlier valid: the rejected value is unknown, so the valid
		// evidence survives (unknown never overwrites known).
		let merged = valid.merging(latest: hostile)
		XCTAssertEqual(merged.costCurrency, "USD")

		// Earlier hostile under later valid: valid wins.
		let mergedOther = hostile.merging(latest: valid)
		XCTAssertEqual(mergedOther.costCurrency, "USD")

		// Repeated merging of hostile payloads can never accumulate the original string.
		var accumulated = hostile
		for _ in 0..<20 {
			accumulated = accumulated.merging(latest: hostile)
		}
		XCTAssertNil(accumulated.costCurrency)
		XCTAssertLessThanOrEqual(accumulated.retainedProvenanceByteCount, OpenCodeUsageSnapshot.maxRetainedProvenanceBytes)
	}

	/// The DESIGNATED initializer is the choke point: a direct construction (the path
	/// merging and cache retention use) cannot store an out-of-policy value either.
	func testDirectInitializationCannotStoreOversizedCurrency() {
		let oversized = String(repeating: "C", count: 100_000)
		let snapshot = OpenCodeUsageSnapshot(
			inputTokens: 1, outputTokens: 2, reasoningTokens: nil, cacheReadTokens: nil,
			cacheWriteTokens: nil, contextUsedTokens: 10, contextWindowTokens: 100,
			costAmount: 1.0, costCurrency: oversized, source: .promptResponse,
			rawProvenanceJSON: nil
		)
		XCTAssertNil(snapshot.costCurrency, "no construction path may retain an out-of-policy currency")

		let bounded = OpenCodeUsageSnapshot(
			inputTokens: 1, outputTokens: 2, reasoningTokens: nil, cacheReadTokens: nil,
			cacheWriteTokens: nil, contextUsedTokens: 10, contextWindowTokens: 100,
			costAmount: 1.0, costCurrency: "USD", source: .promptResponse,
			rawProvenanceJSON: nil
		)
		XCTAssertEqual(bounded.costCurrency, "USD")
	}

	// MARK: - Scalar-string audit: the snapshot retains no other unbounded provider string

	/// `costCurrency` was the only provider-controlled scalar String stored outside the
	/// bounded provenance evidence. This pins the audit: every retained provenance entry
	/// is byte-bounded even when the payload is dominated by huge unknown string fields.
	func testNoOtherScalarStringEscapesTheProvenanceBound() throws {
		let huge = String(repeating: "Z", count: 2_000_000)
		let object = try parsedObject(
			"{\"used\":5,\"model\":\"\(huge)\",\"cost\":{\"amount\":0.5,\"currency\":\"USD\",\"note\":\"\(huge)\"}}"
		)
		let snapshot = OpenCodeUsageSnapshot.decode(usageObject: object, source: .usageUpdate)
		XCTAssertEqual(snapshot.costCurrency, "USD")
		XCTAssertLessThanOrEqual(snapshot.retainedProvenanceByteCount, OpenCodeUsageSnapshot.maxRetainedProvenanceBytes)
		for entry in snapshot.provenanceTrail {
			XCTAssertLessThanOrEqual(entry.rawJSON?.utf8.count ?? 0, OpenCodeUsageSnapshot.maxProvenanceEntryPreviewBytes)
		}
	}
}

import XCTest
@testable import OpenCodeRuntimeKit

/// Eleventh acceptance-remediation round (2026-07-23), core-package half:
/// - finding 1: a representable `Int.max` usage count must not become an addend that
///   overflows; the domain-bounded reader rejects it as unknown;
/// - adjacent audit: the capability-snapshot digest must frame list ELEMENTS so two
///   distinct advertisements cannot collide.
final class OpenCodeEleventhReviewCoreTests: XCTestCase {
	private func parsedObject(_ json: String) throws -> [String: Any] {
		try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
	}

	// MARK: - Finding 1: usage domain bound

	/// `nonNegativeCount` correctly accepts an exact `Int.max` — that is the right
	/// contract for a general parser — but a value that will be ADDED must be
	/// domain-bounded, or `a + b` traps. `boundedUsageCount` rejects it as unknown.
	func testExactIntMaxIsAcceptedByCountButRejectedByUsageBound() throws {
		let object = try parsedObject(#"{"a":9223372036854775807}"#)
		XCTAssertEqual(OpenCodeJSONNumberPolicy.nonNegativeCount(object["a"]), Int.max,
					   "the general exact-count contract is unchanged")
		XCTAssertNil(OpenCodeJSONNumberPolicy.boundedUsageCount(object["a"]),
					 "a usage count near Int.max is not evidence and must be unknown before any addition")
	}

	/// The concrete reported expression: `inputTokens = Int.max, cachedReadTokens = 1`.
	/// Both bound to unknown, so the three-way sum in `messageStopResult` cannot overflow.
	func testHostileUsageBreakdownBoundsToUnknownNotAWrappedSum() throws {
		let object = try parsedObject(#"{"inputTokens":9223372036854775807,"cachedReadTokens":1,"cachedWriteTokens":2}"#)
		let input = OpenCodeJSONNumberPolicy.boundedUsageCount(object["inputTokens"])
		let cachedRead = OpenCodeJSONNumberPolicy.boundedUsageCount(object["cachedReadTokens"])
		let cachedWrite = OpenCodeJSONNumberPolicy.boundedUsageCount(object["cachedWriteTokens"])
		XCTAssertNil(input, "the out-of-domain input is unknown")
		XCTAssertEqual(cachedRead, 1)
		XCTAssertEqual(cachedWrite, 2)
		// This is the exact production expression; reaching it at all proves it no longer traps.
		let sum = (input ?? 0) + (cachedRead ?? 0) + (cachedWrite ?? 0)
		XCTAssertEqual(sum, 3, "only in-domain evidence contributes; nothing is fabricated")
	}

	/// In-domain values are unchanged: the bound does not clamp legitimate usage.
	func testInDomainUsageCountsAreUnchanged() throws {
		let object = try parsedObject(#"{"used":123456,"zero":0,"atBound":1000000000000,"overBound":1000000000001}"#)
		XCTAssertEqual(OpenCodeJSONNumberPolicy.boundedUsageCount(object["used"]), 123_456)
		XCTAssertEqual(OpenCodeJSONNumberPolicy.boundedUsageCount(object["zero"]), 0)
		XCTAssertEqual(OpenCodeJSONNumberPolicy.boundedUsageCount(object["atBound"]),
					   OpenCodeJSONNumberPolicy.maxUsageTokenCount, "the bound itself is admissible")
		XCTAssertNil(OpenCodeJSONNumberPolicy.boundedUsageCount(object["overBound"]),
					 "one past the bound is unknown")
	}

	/// A sum of the maximum number of maximum in-domain counts stays inside `Int`.
	func testDomainBoundGuaranteesNonTrappingSums() {
		let maxCount = OpenCodeJSONNumberPolicy.maxUsageTokenCount
		// Four breakdown fields, each at the domain bound: 4e12, far under Int.max ≈ 9.2e18.
		let sum = maxCount + maxCount + maxCount + maxCount
		XCTAssertEqual(sum, 4 * maxCount)
		XCTAssertLessThan(sum, Int.max)
	}

	/// The `Int` overload (defense in depth for consumers that receive counts as `Int`).
	func testIntOverloadRejectsOutOfDomainAndNegative() {
		XCTAssertEqual(OpenCodeJSONNumberPolicy.boundedUsageCount(500), 500)
		XCTAssertNil(OpenCodeJSONNumberPolicy.boundedUsageCount(Int.max))
		XCTAssertNil(OpenCodeJSONNumberPolicy.boundedUsageCount(-1))
	}

	// MARK: - Adjacent audit: digest list-element framing

	/// The collision the framing prevents: `["a", "b,c"]` and `["a,b", "c"]` both render
	/// `"a,b,c"` under a "," join. With per-element framing their digests differ.
	func testAuthMethodListsThatWouldCollideUnderJoinNowDiffer() throws {
		func snapshot(_ authMethods: [[String: Any]]) -> OpenCodeCapabilitySnapshot {
			OpenCodeCapabilitySnapshot.decode(initializeResponse: [
				"protocolVersion": 1,
				"authMethods": authMethods
			])
		}
		let a = snapshot([["id": "a"], ["id": "b,c"]])
		let b = snapshot([["id": "a,b"], ["id": "c"]])
		XCTAssertEqual(a.authMethodIDs.sorted(), ["a", "b,c"])
		XCTAssertEqual(b.authMethodIDs.sorted(), ["a,b", "c"])
		XCTAssertNotEqual(a.digest, b.digest, "distinct advertisements must never share a digest")
	}

	/// The same guarantee for the unknown-capability list.
	func testUnknownCapabilityListsThatWouldCollideUnderJoinNowDiffer() {
		func snapshot(_ extras: [String: Any]) -> OpenCodeCapabilitySnapshot {
			var caps: [String: Any] = ["loadSession": true]
			for (key, value) in extras { caps[key] = value }
			return OpenCodeCapabilitySnapshot.decode(initializeResponse: [
				"protocolVersion": 1,
				"agentCapabilities": caps
			])
		}
		// Two different sets of unknown keys that could collapse to the same joined string.
		let a = snapshot(["x": 1, "y,z": 1])
		let b = snapshot(["x,y": 1, "z": 1])
		XCTAssertNotEqual(a.digest, b.digest)
	}

	/// The documented 1.18.4-shaped advertisement still produces a STABLE digest — the
	/// framing change must be deterministic, not order-dependent.
	func testWellFormedSnapshotDigestIsStableAcrossDecodes() throws {
		let response = try parsedObject("""
		{"protocolVersion":1,"agentInfo":{"name":"OpenCode","version":"1.18.4"},
		 "authMethods":[{"id":"oauth"}],
		 "agentCapabilities":{"loadSession":true,"sessionCapabilities":{"resume":{},"list":true,"close":{}}}}
		""")
		let first = OpenCodeCapabilitySnapshot.decode(initializeResponse: response)
		let second = OpenCodeCapabilitySnapshot.decode(initializeResponse: response)
		XCTAssertEqual(first.digest, second.digest)
	}
}

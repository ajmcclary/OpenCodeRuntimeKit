import XCTest
@testable import OpenCodeRuntimeKit

/// Thirteenth acceptance-remediation round (2026-07-23), core-package half:
/// - finding 6: usage provenance is bounded by BYTES, not just entry count — a hostile
///   multi-megabyte `rawJSON` is truncated to a bounded preview plus a full-content
///   digest, and the per-snapshot retained byte total is concretely bounded.
final class OpenCodeThirteenthReviewCoreTests: XCTestCase {
	private func parsedObject(_ json: String) throws -> [String: Any] {
		try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
	}

	// MARK: - Finding 6: byte-bounded provenance

	/// A single hostile usage payload with a multi-megabyte unknown field is retained only
	/// as a bounded preview; the full bytes are fingerprinted, and the rejected fact stays
	/// visible (the field is unknown, not fabricated into a reading).
	func testOversizedProvenanceIsTruncatedToBoundedPreviewWithDigest() throws {
		let huge = String(repeating: "A", count: 4_000_000)
		let object = try parsedObject("{\"used\":1234,\"junk\":\"\(huge)\"}")
		let snapshot = OpenCodeUsageSnapshot.decode(usageObject: object, source: .usageUpdate)

		XCTAssertEqual(snapshot.contextUsedTokens, 1234, "the legitimate reading survives")
		let entry = try XCTUnwrap(snapshot.provenanceTrail.last)
		XCTAssertTrue(entry.isTruncated, "an oversized payload is truncated")
		XCTAssertLessThanOrEqual(
			entry.rawJSON?.utf8.count ?? 0, OpenCodeUsageSnapshot.maxProvenanceEntryPreviewBytes,
			"the retained preview is within the per-entry byte bound"
		)
		XCTAssertGreaterThan(entry.originalByteCount, 4_000_000, "the original byte count is recorded")
		XCTAssertNotNil(entry.digestHex, "the full content is fingerprinted")
		XCTAssertTrue(entry.rawJSON?.contains("sha256:") == true, "the preview marker names the digest")
	}

	/// The retained provenance byte total across a MERGED, multi-source snapshot is bounded
	/// by the documented maximum — many large distinct payloads cannot accumulate without
	/// bound.
	func testMergedProvenanceByteTotalIsBounded() throws {
		var snapshot: OpenCodeUsageSnapshot?
		for index in 0..<40 {
			let huge = String(repeating: "\(index % 10)", count: 2_000_000)
			let object = try parsedObject("{\"used\":\(index + 1),\"blob\":\"\(huge)\"}")
			let next = OpenCodeUsageSnapshot.decode(usageObject: object, source: .usageUpdate)
			snapshot = snapshot.map { $0.merging(latest: next) } ?? next
		}
		let merged = try XCTUnwrap(snapshot)
		XCTAssertLessThanOrEqual(
			merged.retainedProvenanceByteCount, OpenCodeUsageSnapshot.maxRetainedProvenanceBytes,
			"the retained provenance byte total across the trail is bounded"
		)
		XCTAssertLessThanOrEqual(
			merged.provenanceTrail.count, OpenCodeUsageSnapshot.maxRetainedProvenanceEntries,
			"the entry-count bound still holds too"
		)
	}

	/// A small legitimate payload is retained verbatim, un-truncated, with no digest noise.
	func testSmallProvenanceIsRetainedVerbatim() throws {
		let object = try parsedObject(#"{"used":10,"size":200000}"#)
		let snapshot = OpenCodeUsageSnapshot.decode(usageObject: object, source: .usageUpdate)
		let entry = try XCTUnwrap(snapshot.provenanceTrail.last)
		XCTAssertFalse(entry.isTruncated)
		XCTAssertNil(entry.digestHex, "no digest is computed for an un-truncated payload")
		XCTAssertEqual(entry.rawJSON, #"{"size":200000,"used":10}"#, "the sorted-keys serialization is retained verbatim")
	}

	/// The concrete per-snapshot and per-cache byte ceilings are the documented constants.
	func testDocumentedByteCeilings() {
		XCTAssertEqual(OpenCodeUsageSnapshot.maxProvenanceEntryPreviewBytes, 4096)
		XCTAssertEqual(
			OpenCodeUsageSnapshot.maxRetainedProvenanceBytes,
			OpenCodeUsageSnapshot.maxRetainedProvenanceEntries * 4096
		)
	}
}

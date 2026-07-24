import XCTest
@testable import OpenCodeRuntimeKit

/// Fifth acceptance-remediation round — pure-core regressions.
///
/// Covers the core half of findings 1 (chunk-additive coverage), 2 (required replay
/// coverage), 3 (cryptographic content proof + legacy fail-closed), 5 (semantic usage
/// projection) and 6 (bounded provenance retention).
final class OpenCodeFifthReviewCoreTests: XCTestCase {

	// MARK: - Finding 3: resumable SHA-256

	/// The whole point of the resumable state: a stream chopped anywhere reaches the
	/// same digest as the one-shot digest of the concatenation.
	func testIncrementalDigestMatchesOneShotDigestForEveryChunking() {
		let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 7)
		let expected = OpenCodeSHA256Digest.digest(ofUTF8: text).value
		let bytes = Array(text.utf8)
		for stride in [1, 7, 63, 64, 65, 127, 128, 200, bytes.count] {
			var incremental = OpenCodeIncrementalSHA256()
			var index = 0
			while index < bytes.count {
				let end = min(index + stride, bytes.count)
				incremental.update(bytes[index..<end])
				index = end
			}
			XCTAssertEqual(
				incremental.finalizedHex(),
				expected,
				"chunking at \(stride) bytes must not change the digest"
			)
		}
	}

	func testIncrementalDigestOfEmptyInputMatchesKnownVector() {
		let empty = OpenCodeIncrementalSHA256()
		XCTAssertEqual(
			empty.finalizedHex(),
			"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
		)
		XCTAssertTrue(empty.isEmpty)
	}

	/// Finalizing must not consume the state: replay verification finalizes to compare
	/// while more chunks may still arrive.
	func testFinalizingDoesNotConsumeTheState() {
		var digest = OpenCodeIncrementalSHA256()
		digest.update(utf8: "abc")
		let first = digest.finalizedHex()
		XCTAssertEqual(first, OpenCodeSHA256Digest.digest(ofUTF8: "abc").value)
		XCTAssertEqual(digest.finalizedHex(), first, "finalize must be non-mutating")
		digest.update(utf8: "def")
		XCTAssertEqual(digest.finalizedHex(), OpenCodeSHA256Digest.digest(ofUTF8: "abcdef").value)
	}

	func testIncrementalDigestStateRoundTripsThroughCodable() throws {
		var digest = OpenCodeIncrementalSHA256()
		digest.update(utf8: "partially absorbed text that does not end on a block boundary")
		let decoded = try JSONDecoder().decode(
			OpenCodeIncrementalSHA256.self,
			from: try JSONEncoder().encode(digest)
		)
		XCTAssertEqual(decoded, digest)
		var continued = decoded
		continued.update(utf8: " and the rest")
		var reference = digest
		reference.update(utf8: " and the rest")
		XCTAssertEqual(continued.finalizedHex(), reference.finalizedHex())
	}

	// MARK: - Finding 1: chunk-additive coverage across grapheme boundaries

	/// The shipped defect: live chunks "e" and U+0301 counted 2 characters, the combined
	/// replay chunk "é" counted 1, and a valid replay was refused.
	func testCoverageIsAdditiveWhenLiveSplitsACombiningSequence() {
		var split = OpenCodeTranscriptFrontier()
		split = split.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "e")
		split = split.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "\u{301}")
		var combined = OpenCodeTranscriptFrontier()
		combined = combined.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "e\u{301}")

		XCTAssertEqual(split.observedTextScalarCount(forMessageID: "m1"), 2)
		XCTAssertEqual(
			split.observedTextScalarCount(forMessageID: "m1"),
			combined.observedTextScalarCount(forMessageID: "m1"),
			"coverage must be additive across chunk boundaries; grapheme counts are not"
		)
		XCTAssertEqual(
			split.observedTextDigest(forMessageID: "m1")?.finalizedHex(),
			combined.observedTextDigest(forMessageID: "m1")?.finalizedHex()
		)
	}

	func testCoverageIsAdditiveForMultiScalarEmojiSequences() {
		// A ZWJ family emoji: one grapheme, seven scalars.
		let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
		XCTAssertEqual(family.count, 1, "precondition: one extended grapheme cluster")
		var split = OpenCodeTranscriptFrontier()
		for scalar in family.unicodeScalars {
			split = split.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: String(scalar))
		}
		var whole = OpenCodeTranscriptFrontier()
		whole = whole.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: family)

		XCTAssertEqual(split.observedTextScalarCount(forMessageID: "m1"), 7)
		XCTAssertEqual(whole.observedTextScalarCount(forMessageID: "m1"), 7)
		XCTAssertEqual(
			split.observedTextDigest(forMessageID: "m1")?.finalizedHex(),
			whole.observedTextDigest(forMessageID: "m1")?.finalizedHex()
		)
	}

	func testEqualCoverageWithDifferentContentIsDistinguishable() {
		var a = OpenCodeTranscriptFrontier()
		a = a.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "abcdef")
		var b = OpenCodeTranscriptFrontier()
		b = b.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "abcdeg")
		XCTAssertEqual(a.observedTextScalarCount(forMessageID: "m1"), b.observedTextScalarCount(forMessageID: "m1"))
		XCTAssertNotEqual(
			a.observedTextDigest(forMessageID: "m1")?.finalizedHex(),
			b.observedTextDigest(forMessageID: "m1")?.finalizedHex()
		)
	}

	// MARK: - Finding 2: required replay coverage

	func testObservingMessageTextMarksItAsRequiringReplayCoverage() {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "hello")
		frontier = frontier.advanced(messageID: "m2", toolCallID: nil, observedTextChunk: nil)

		XCTAssertTrue(frontier.requiresReplayCoverage(forMessageID: "m1"))
		XCTAssertFalse(
			frontier.requiresReplayCoverage(forMessageID: "m2"),
			"a message with no observed text has no rendered prefix to prove"
		)
	}

	func testCompletedTurnClearsTheCoverageRequirementButKeepsTheEvidence() {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "hello")
		let completed = frontier.clearingRequiredReplayCoverage()

		XCTAssertFalse(
			completed.requiresReplayCoverage(forMessageID: "m1"),
			"sparse history for a finished message is legal; only in-flight messages must be proven"
		)
		XCTAssertEqual(completed.observedTextScalarCount(forMessageID: "m1"), 5, "dedup evidence must survive")
		XCTAssertEqual(
			completed.observedTextDigest(forMessageID: "m1")?.finalizedHex(),
			frontier.observedTextDigest(forMessageID: "m1")?.finalizedHex()
		)
	}

	// MARK: - Finding 3: legacy content evidence fails closed

	func testVersionOneContentEvidenceDecodesAsUnsupportedAndIsNeverReinterpreted() throws {
		// A version-1 record: character counts and FNV-1a-64 "checksums", no version key.
		let legacy = #"""
		{"seenMessageIDs":["m1"],"seenToolCallIDs":[],"lastEventOrdinal":9,
		 "observedMessageTextLengths":{"m1":12},
		 "observedMessageTextChecksums":{"m1":1234567890}}
		"""#
		let decoded = try JSONDecoder().decode(OpenCodeTranscriptFrontier.self, from: Data(legacy.utf8))

		XCTAssertTrue(decoded.hasUnsupportedContentEvidence)
		XCTAssertNil(
			decoded.observedTextScalarCount(forMessageID: "m1"),
			"a version-1 character count must never be reused as a scalar count"
		)
		XCTAssertNil(
			decoded.observedTextDigest(forMessageID: "m1"),
			"an FNV value must never be reinterpreted as a SHA-256 state"
		)
		XCTAssertTrue(decoded.containsReplay(messageID: "m1", toolCallID: nil), "identifiers still dedup wholly")
	}

	func testPreCoverageRecordWithoutContentEvidenceStaysSupported() throws {
		let legacy = #"{"seenMessageIDs":["m1"],"seenToolCallIDs":["t1"],"lastEventOrdinal":4}"#
		let decoded = try JSONDecoder().decode(OpenCodeTranscriptFrontier.self, from: Data(legacy.utf8))
		XCTAssertFalse(
			decoded.hasUnsupportedContentEvidence,
			"a frontier that recorded no content evidence at all is not a legacy-evidence record"
		)
	}

	func testFutureContentEvidenceVersionAlsoFailsClosed() throws {
		let future = #"{"seenMessageIDs":["m1"],"contentEvidenceVersion":99,"observedMessageTextScalarCounts":{"m1":3}}"#
		let decoded = try JSONDecoder().decode(OpenCodeTranscriptFrontier.self, from: Data(future.utf8))
		XCTAssertTrue(decoded.hasUnsupportedContentEvidence)
		XCTAssertNil(decoded.observedTextScalarCount(forMessageID: "m1"))
	}

	func testUnsupportedEvidenceFlagSurvivesAReEncode() throws {
		let legacy = #"{"seenMessageIDs":["m1"],"observedMessageTextLengths":{"m1":12}}"#
		let decoded = try JSONDecoder().decode(OpenCodeTranscriptFrontier.self, from: Data(legacy.utf8))
		let round = try JSONDecoder().decode(
			OpenCodeTranscriptFrontier.self,
			from: try JSONEncoder().encode(decoded)
		)
		XCTAssertTrue(round.hasUnsupportedContentEvidence, "the fail-closed flag must be sticky")
	}

	func testEncodedFrontierCarriesTheVersionAndNoLegacyKeys() throws {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "hello")
		let json = try XCTUnwrap(String(data: try JSONEncoder().encode(frontier), encoding: .utf8))
		XCTAssertTrue(json.contains("\"contentEvidenceVersion\":2"))
		XCTAssertFalse(json.contains("observedMessageTextLengths"))
		XCTAssertFalse(json.contains("observedMessageTextChecksums"))
	}

	func testRequiredCoverageAndVersionTwoEvidenceRoundTrip() throws {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: "t1", observedTextChunk: "e\u{301}x", toolCallReachedTerminal: true)
		let decoded = try JSONDecoder().decode(
			OpenCodeTranscriptFrontier.self,
			from: try JSONEncoder().encode(frontier)
		)
		XCTAssertEqual(decoded, frontier)
		XCTAssertEqual(decoded.observedTextScalarCount(forMessageID: "m1"), 3)
		XCTAssertTrue(decoded.requiresReplayCoverage(forMessageID: "m1"))
		XCTAssertEqual(
			decoded.observedTextDigest(forMessageID: "m1")?.finalizedHex(),
			OpenCodeSHA256Digest.digest(ofUTF8: "e\u{301}x").value
		)
	}

	// MARK: - Planner fails closed on unusable frontiers

	func testPlannerRefusesUnsupportedContentEvidenceBeforeAnyRecoveryPath() throws {
		let legacy = try JSONDecoder().decode(
			OpenCodeTranscriptFrontier.self,
			from: Data(#"{"seenMessageIDs":["m1"],"observedMessageTextLengths":{"m1":12}}"#.utf8)
		)
		let plan = OpenCodeSessionRecoveryPlanner.plan(makeContext(frontier: legacy))
		XCTAssertEqual(plan, .refuse(.frontierContentEvidenceUnsupported))
	}

	func testPlannerRefusesAnOverflowedFrontier() {
		var frontier = OpenCodeTranscriptFrontier()
		for index in 0...OpenCodeTranscriptFrontier.maxTrackedIdentifiers {
			frontier = frontier.advanced(messageID: "m\(index)", toolCallID: nil)
		}
		XCTAssertTrue(frontier.didOverflow)
		XCTAssertEqual(
			OpenCodeSessionRecoveryPlanner.plan(makeContext(frontier: frontier)),
			.refuse(.frontierOverflowed)
		)
	}

	func testPlannerStillResumesWithAHealthyFrontier() {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "hello")
		XCTAssertEqual(
			OpenCodeSessionRecoveryPlanner.plan(makeContext(frontier: frontier)),
			.resume(sessionID: "session-1")
		)
	}

	private func makeContext(frontier: OpenCodeTranscriptFrontier) -> OpenCodeSessionRecoveryContext {
		let sha = OpenCodeSHA256(String(repeating: "9a", count: 32))!
		let identity = OpenCodeRuntimeIdentity(
			resolvedPath: "/Users/dev/.opencode/bin/opencode",
			realPath: "/Users/dev/.opencode/bin/opencode",
			sha256: sha,
			sizeBytes: 1000,
			modificationEpochSeconds: nil,
			architecture: .arm64,
			signingClass: .adHoc,
			pathClass: .openCodeManagedBin,
			cliVersion: OpenCodeCliVersion(string: "1.18.4")!
		)!
		return OpenCodeSessionRecoveryContext(
			record: OpenCodeSessionRecoveryRecord(
				providerSessionID: "session-1",
				canonicalRootPath: "/tmp/ws",
				runtimeSHA256Hex: sha.value,
				cliVersion: "1.18.4",
				modelSelectionRaw: nil,
				sessionModeID: nil,
				frontier: frontier
			),
			currentCanonicalRootPath: "/tmp/ws",
			currentRuntime: .resolved(identity),
			admissionDecision: .admitObserveOnly(.unknownRuntime),
			effectiveCapabilities: OpenCodeEffectiveSessionCapabilities(
				appPolicy: .init(loadSession: true, listSessions: true, resumeSession: true, closeSession: true, unstableForkSession: false),
				advertised: .init(loadSession: true, listSessions: true, resumeSession: true, closeSession: true, unstableForkSession: false)
			),
			recoveryAttemptsMade: 0
		)
	}

	// MARK: - Finding 5: semantic usage projection

	func testSemanticProjectionIgnoresSourceAndRawProvenance() {
		let fromUpdate = OpenCodeUsageSnapshot.decode(
			usageObject: ["used": 100, "size": 1000, "cost": ["amount": 0.25, "currency": "USD"]],
			source: .usageUpdate
		)
		let fromResponse = OpenCodeUsageSnapshot.decode(
			usageObject: ["used": 100, "size": 1000, "cost": ["amount": 0.25, "currency": "USD"], "vendorNote": "different raw"],
			source: .promptResponse
		)
		XCTAssertNotEqual(fromUpdate, fromResponse, "the snapshots genuinely differ in provenance")
		XCTAssertEqual(
			fromUpdate.semanticProjection,
			fromResponse.semanticProjection,
			"what the usage EVENT can express is identical, so it must not be emitted twice"
		)
	}

	func testSemanticProjectionIsEmptyWhenNothingProjectable() {
		let tokensOnly = OpenCodeUsageSnapshot.decode(
			usageObject: ["inputTokens": 12, "outputTokens": 3],
			source: .promptResponse
		)
		XCTAssertTrue(tokensOnly.semanticProjection.isEmpty)
		XCTAssertEqual(tokensOnly.inputTokens, 12, "the evidence is still retained")
	}

	// MARK: - Finding 6: bounded provenance retention

	func testMergingRetainsEveryContributingRawSource() {
		let contextUpdate = OpenCodeUsageSnapshot.decode(
			usageObject: ["used": 100, "size": 1000],
			source: .usageUpdate
		)
		let costResponse = OpenCodeUsageSnapshot.decode(
			usageObject: ["cost": ["amount": 0.5, "currency": "USD"]],
			source: .promptResponse
		)
		let merged = contextUpdate.merging(latest: costResponse)

		XCTAssertEqual(merged.provenanceTrail.count, 2, "the earlier payload's provenance must not be replaced")
		XCTAssertEqual(merged.provenanceTrail.first?.source, .usageUpdate)
		XCTAssertEqual(merged.provenanceTrail.first?.rawJSON, #"{"size":1000,"used":100}"#)
		XCTAssertEqual(merged.provenanceTrail.last?.source, .promptResponse)
		XCTAssertEqual(merged.contributingSources, [.usageUpdate, .promptResponse])
		XCTAssertTrue(merged.isMixedSource, "a mixed-source snapshot must say so")
		XCTAssertEqual(merged.rawProvenanceJSON, merged.provenanceTrail.last?.rawJSON)
		XCTAssertEqual(merged.contextUsedTokens, 100)
		XCTAssertEqual(merged.costAmount, 0.5)
	}

	func testIdenticalRepeatedPayloadsCollapseInTheProvenanceTrail() {
		let payload: [String: Any] = ["used": 10, "size": 100]
		var merged = OpenCodeUsageSnapshot.decode(usageObject: payload, source: .usageUpdate)
		for _ in 0..<20 {
			merged = merged.merging(latest: OpenCodeUsageSnapshot.decode(usageObject: payload, source: .usageUpdate))
		}
		XCTAssertEqual(merged.provenanceTrail.count, 1)
		XCTAssertEqual(merged.droppedProvenanceCount, 0)
		XCTAssertFalse(merged.isMixedSource)
	}

	func testProvenanceRetentionIsBoundedAndReportsWhatItDropped() {
		var merged = OpenCodeUsageSnapshot.decode(usageObject: ["used": 0], source: .usageUpdate)
		for index in 1...20 {
			merged = merged.merging(latest: OpenCodeUsageSnapshot.decode(
				usageObject: ["used": index],
				source: .usageUpdate
			))
		}
		XCTAssertEqual(merged.provenanceTrail.count, OpenCodeUsageSnapshot.maxRetainedProvenanceEntries)
		XCTAssertGreaterThan(merged.droppedProvenanceCount, 0, "truncation must be visible, never silent")
		XCTAssertEqual(
			merged.provenanceTrail.first?.rawJSON,
			#"{"used":0}"#,
			"the earliest provenance is retained"
		)
		XCTAssertEqual(
			merged.provenanceTrail.last?.rawJSON,
			#"{"used":20}"#,
			"the most recent provenance is always retained"
		)
	}
}

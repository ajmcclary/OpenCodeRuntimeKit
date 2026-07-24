import XCTest
@testable import OpenCodeRuntimeKit

/// Sixth acceptance-remediation round — pure-core regressions.
///
/// Covers finding 1 (persisted SHA-256 and frontier state are validated, not trusted),
/// finding 5 (the semantic projection matches the real downstream event surface), and
/// finding 7 (contributing-source truth survives bounded raw-payload retention).
final class OpenCodeSixthReviewCoreTests: XCTestCase {

	// MARK: - Finding 1: persisted SHA-256 state is untrusted input

	private func decodeDigest(_ json: String) throws -> OpenCodeIncrementalSHA256 {
		try JSONDecoder().decode(OpenCodeIncrementalSHA256.self, from: Data(json.utf8))
	}

	/// Each of these decoded cleanly under the synthesized conformance and then trapped
	/// inside `finalizedHex()` — indexing past the chaining words, or hitting the
	/// 64-byte block precondition. A malformed recovery file must REFUSE, not crash.
	func testMalformedSHAStateFailsToDecodeInsteadOfTrappingLater() {
		let malformed: [(name: String, json: String)] = [
			("empty state", #"{"state":[],"tail":[],"byteCount":0}"#),
			("short state", #"{"state":[1,2,3],"tail":[],"byteCount":0}"#),
			("long state", #"{"state":[1,2,3,4,5,6,7,8,9],"tail":[],"byteCount":0}"#),
			("oversized tail", #"{"state":[1,2,3,4,5,6,7,8],"tail":[\#(Array(repeating: "1", count: 64).joined(separator: ","))],"byteCount":64}"#),
			("byteCount below tail", #"{"state":[1,2,3,4,5,6,7,8],"tail":[1,2,3],"byteCount":1}"#),
			("byteCount inconsistent with tail", #"{"state":[1,2,3,4,5,6,7,8],"tail":[1,2,3],"byteCount":10}"#),
			("bit-length overflow", #"{"state":[1,2,3,4,5,6,7,8],"tail":[],"byteCount":18446744073709551552}"#)
		]
		for case let (name, json) in malformed {
			XCTAssertThrowsError(try decodeDigest(json), "\(name) must fail closed") { error in
				XCTAssertTrue(error is DecodingError, "\(name): expected a decoding failure, got \(error)")
			}
		}
	}

	func testWellFormedResumedStateStillDecodesAndContinues() throws {
		var digest = OpenCodeIncrementalSHA256()
		digest.update(utf8: String(repeating: "block-aligned-and-then-some ", count: 5))
		let decoded = try decodeDigest(
			String(data: try JSONEncoder().encode(digest), encoding: .utf8)!
		)
		XCTAssertEqual(decoded, digest)
		var continued = decoded
		continued.update(utf8: "tail")
		var reference = digest
		reference.update(utf8: "tail")
		XCTAssertEqual(continued.finalizedHex(), reference.finalizedHex())
	}

	/// A 64-byte-aligned stream has an EMPTY tail and a byteCount that is a multiple of
	/// 64; the validator must accept exactly that shape.
	func testBlockAlignedStateSatisfiesTheByteCountInvariant() throws {
		var digest = OpenCodeIncrementalSHA256()
		digest.update(utf8: String(repeating: "x", count: 128))
		XCTAssertEqual(digest.byteCount, 128)
		let decoded = try decodeDigest(String(data: try JSONEncoder().encode(digest), encoding: .utf8)!)
		XCTAssertEqual(decoded.finalizedHex(), digest.finalizedHex())
	}

	// MARK: - Finding 1: persisted frontier state is untrusted input

	private func decodeFrontier(_ json: String) throws -> OpenCodeTranscriptFrontier {
		try JSONDecoder().decode(OpenCodeTranscriptFrontier.self, from: Data(json.utf8))
	}

	private func assertUnsupported(
		_ json: String,
		_ why: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) throws {
		let decoded = try decodeFrontier(json)
		XCTAssertTrue(decoded.hasUnsupportedContentEvidence, why, file: file, line: line)
		XCTAssertTrue(decoded.observedMessageTextScalarCounts.isEmpty, "evidence must be dropped, not filtered", file: file, line: line)
		XCTAssertTrue(decoded.requiredReplayCoverageMessageIDs.isEmpty, file: file, line: line)
	}

	/// The defect: a negative required coverage compares as already-satisfied, so the
	/// proof check is skipped and the complete replay is delivered on top of content
	/// that was already rendered.
	func testNegativeScalarCoverageIsUnsupported() throws {
		try assertUnsupported(
			#"{"seenMessageIDs":["m1"],"contentEvidenceVersion":2,"observedMessageTextScalarCounts":{"m1":-5}}"#,
			"negative coverage must never be accepted as a satisfied requirement"
		)
	}

	func testAbsurdlyLargeScalarCoverageIsUnsupported() throws {
		try assertUnsupported(
			#"{"seenMessageIDs":["m1"],"contentEvidenceVersion":2,"observedMessageTextScalarCounts":{"m1":999999999}}"#,
			"coverage beyond any plausible transcript is not evidence"
		)
	}

	/// Version-2 fields with NO version key: not a pre-evidence record, and not a
	/// record this build wrote. The fifth round accepted it.
	func testMissingVersionWithVersionTwoFieldsIsUnsupported() throws {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "hello")
		var object = try JSONSerialization.jsonObject(
			with: try JSONEncoder().encode(frontier)
		) as! [String: Any]
		object.removeValue(forKey: "contentEvidenceVersion")
		object.removeValue(forKey: "hasUnsupportedContentEvidence")
		let json = String(
			data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
			encoding: .utf8
		)!
		try assertUnsupported(json, "version-2 fields without the version key must fail closed")
	}

	func testPositiveCoverageWithoutDigestEvidenceIsUnsupported() throws {
		try assertUnsupported(
			#"{"seenMessageIDs":["m1"],"contentEvidenceVersion":2,"observedMessageTextScalarCounts":{"m1":5}}"#,
			"coverage without content proof is exactly the length-only trust that was removed"
		)
	}

	func testDigestWithoutCoverageRecordIsUnsupported() throws {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "hello")
		var object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(frontier)) as! [String: Any]
		object["observedMessageTextScalarCounts"] = [String: Int]()
		object.removeValue(forKey: "hasUnsupportedContentEvidence")
		let json = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
		try assertUnsupported(json, "a digest with no coverage record is an inconsistent pair")
	}

	/// UTF-8 encodes 1–4 bytes per scalar: a digest claiming to have absorbed fewer
	/// bytes than there are scalars cannot be evidence for that coverage.
	func testDigestByteCountInconsistentWithCoverageIsUnsupported() throws {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "hello")
		var object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(frontier)) as! [String: Any]
		object["observedMessageTextScalarCounts"] = ["m1": 500]
		object.removeValue(forKey: "hasUnsupportedContentEvidence")
		let json = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
		try assertUnsupported(json, "5 absorbed bytes cannot prove 500 scalars of coverage")
	}

	func testCoverageForAnUnseenMessageIsUnsupported() throws {
		try assertUnsupported(
			#"{"seenMessageIDs":["m1"],"contentEvidenceVersion":2,"observedMessageTextScalarCounts":{"ghost":0}}"#,
			"evidence keyed to a message the record never saw is inconsistent"
		)
	}

	func testRequiredCoverageForAnUnseenMessageIsUnsupported() throws {
		try assertUnsupported(
			#"{"seenMessageIDs":["m1"],"contentEvidenceVersion":2,"requiredReplayCoverageMessageIDs":["ghost"]}"#,
			"a required ID outside the seen set must fail closed, never be silently filtered away"
		)
	}

	func testDuplicateRequiredCoverageIDsAreUnsupported() throws {
		try assertUnsupported(
			#"{"seenMessageIDs":["m1"],"contentEvidenceVersion":2,"requiredReplayCoverageMessageIDs":["m1","m1"]}"#,
			"a duplicated requirement is a malformed collection"
		)
	}

	func testDuplicateSeenMessageIDsAreUnsupported() throws {
		try assertUnsupported(
			#"{"seenMessageIDs":["m1","m1"],"contentEvidenceVersion":2}"#,
			"duplicated identifiers make coverage bookkeeping ambiguous"
		)
	}

	func testOversizedEvidenceCollectionsAreUnsupported() throws {
		let ids = (0...OpenCodeTranscriptFrontier.maxTrackedIdentifiers).map { "m\($0)" }
		let counts = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
		let object: [String: Any] = [
			"seenMessageIDs": ids,
			"contentEvidenceVersion": 2,
			"observedMessageTextScalarCounts": counts
		]
		let json = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
		let decoded = try decodeFrontier(json)
		XCTAssertTrue(
			decoded.hasUnsupportedContentEvidence || decoded.didOverflow,
			"an oversized evidence collection must be unsupported or overflowed — either refuses"
		)
	}

	/// A genuinely well-formed version-2 record must survive all of the above.
	func testWellFormedVersionTwoRecordRemainsSupported() throws {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: "t1", observedTextChunk: "hello", toolCallReachedTerminal: true)
		frontier = frontier.advanced(messageID: "m2", toolCallID: nil)
		let decoded = try decodeFrontier(String(data: try JSONEncoder().encode(frontier), encoding: .utf8)!)
		XCTAssertFalse(decoded.hasUnsupportedContentEvidence)
		XCTAssertEqual(decoded, frontier)
	}

	/// A malformed DIGEST inside an otherwise plausible frontier fails the whole
	/// record's decode, which is itself fail-closed: the caller has no frontier to act on.
	func testMalformedDigestInsideAFrontierFailsTheWholeDecode() {
		let json = #"""
		{"seenMessageIDs":["m1"],"contentEvidenceVersion":2,
		 "observedMessageTextScalarCounts":{"m1":5},
		 "observedMessageTextDigests":{"m1":{"state":[1,2],"tail":[],"byteCount":0}}}
		"""#
		XCTAssertThrowsError(try decodeFrontier(json))
	}

	/// The planner must refuse every unsupported shape, not just the version-1 one.
	func testPlannerRefusesStructurallyInvalidEvidence() throws {
		let frontier = try decodeFrontier(
			#"{"seenMessageIDs":["m1"],"contentEvidenceVersion":2,"observedMessageTextScalarCounts":{"m1":-5}}"#
		)
		XCTAssertEqual(
			OpenCodeSessionRecoveryPlanner.plan(makeContext(frontier: frontier)),
			.refuse(.frontierContentEvidenceUnsupported)
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

	// MARK: - Finding 5: the projection must match the real downstream surface

	/// `AIStreamResult` carries a numeric cost and no currency, so two snapshots with
	/// the same amount and different currencies produce byte-identical visible events.
	/// Keeping currency in the dedup key made them compare unequal and emit twice —
	/// the exact defect the projection was introduced to fix.
	func testCurrencyIsEvidenceOnlyAndDoesNotSplitTheSemanticKey() {
		let usd = OpenCodeUsageSnapshot.decode(
			usageObject: ["used": 100, "size": 1000, "cost": ["amount": 0.25, "currency": "USD"]],
			source: .usageUpdate
		)
		let eur = OpenCodeUsageSnapshot.decode(
			usageObject: ["used": 100, "size": 1000, "cost": ["amount": 0.25, "currency": "EUR"]],
			source: .promptResponse
		)
		XCTAssertEqual(
			usd.semanticProjection,
			eur.semanticProjection,
			"equal amounts must share one semantic key; the visible event cannot express currency"
		)
		XCTAssertEqual(usd.costCurrency, "USD")
		XCTAssertEqual(eur.costCurrency, "EUR", "currency is retained as evidence, just not as a dedup axis")
	}

	/// Every evidence-only field must be outside the key, and every projectable field
	/// inside it. This pins the boundary so a future field lands deliberately.
	func testEvidenceOnlyFieldsNeverAffectTheSemanticKey() {
		let base = OpenCodeUsageSnapshot.decode(usageObject: ["used": 1, "size": 2, "cost": 3.0], source: .usageUpdate)
		let enriched = OpenCodeUsageSnapshot.decode(
			usageObject: [
				"used": 1, "size": 2, "cost": 3.0,
				"inputTokens": 9, "outputTokens": 8, "reasoningTokens": 7,
				"cachedReadTokens": 6, "cachedWriteTokens": 5, "vendorExtra": "ignored"
			],
			source: .promptResponse
		)
		XCTAssertEqual(base.semanticProjection, enriched.semanticProjection)
		XCTAssertNotEqual(base, enriched, "the snapshots genuinely differ; only the visible key matches")

		for changed in [
			OpenCodeUsageSnapshot.decode(usageObject: ["used": 99, "size": 2, "cost": 3.0], source: .usageUpdate),
			OpenCodeUsageSnapshot.decode(usageObject: ["used": 1, "size": 99, "cost": 3.0], source: .usageUpdate),
			OpenCodeUsageSnapshot.decode(usageObject: ["used": 1, "size": 2, "cost": 9.0], source: .usageUpdate)
		] {
			XCTAssertNotEqual(base.semanticProjection, changed.semanticProjection, "projectable fields MUST split the key")
		}
	}

	// MARK: - Finding 7: source truth survives bounded raw retention

	/// More than eight unique payloads, with the sole prompt-response contribution in
	/// the dropped middle. Deriving sources from the retained trail erased the fact
	/// that a prompt response contributed at all — while its field was still in the
	/// merged snapshot.
	func testContributingSourcesSurviveWhenTheOnlyPromptResponseEntryIsDropped() {
		var merged = OpenCodeUsageSnapshot.decode(usageObject: ["used": 0], source: .usageUpdate)
		// Enough leading entries that the retained head is already full, so the next
		// contribution lands in the dropped middle rather than the retained prefix.
		for index in 1...7 {
			merged = merged.merging(latest: .decode(usageObject: ["used": index], source: .usageUpdate))
		}
		// The single prompt-response payload, contributing a field nothing else supplies.
		merged = merged.merging(latest: .decode(
			usageObject: ["reasoningTokens": 42],
			source: .promptResponse
		))
		for index in 4...20 {
			merged = merged.merging(latest: .decode(usageObject: ["used": index], source: .usageUpdate))
		}

		XCTAssertEqual(merged.reasoningTokens, 42, "the prompt response's field is still in the snapshot")
		XCTAssertEqual(merged.provenanceTrail.count, OpenCodeUsageSnapshot.maxRetainedProvenanceEntries)
		XCTAssertGreaterThan(merged.droppedProvenanceCount, 0)
		XCTAssertFalse(
			merged.provenanceTrail.contains { $0.source == .promptResponse },
			"precondition: the only prompt-response payload was dropped from the bounded trail"
		)
		XCTAssertEqual(
			merged.contributingSources,
			[.usageUpdate, .promptResponse],
			"source truth is recorded independently of the lossy raw trail"
		)
		XCTAssertTrue(merged.isMixedSource, "a snapshot carrying a prompt-response field is mixed-source, full stop")
	}

	func testContributingSourcesStayBoundedByTheSourceEnum() {
		var merged = OpenCodeUsageSnapshot.decode(usageObject: ["used": 0], source: .usageUpdate)
		for index in 1...50 {
			merged = merged.merging(latest: .decode(
				usageObject: ["used": index],
				source: index.isMultiple(of: 2) ? .promptResponse : .usageUpdate
			))
		}
		XCTAssertEqual(merged.contributingSources.count, 2, "the closed enum bounds this list at two")
		XCTAssertEqual(merged.contributingSources, [.usageUpdate, .promptResponse], "first-contribution order is stable")
	}

	// MARK: - Broader audit: untrusted numeric usage payloads

	/// A JSON boolean bridges to `NSNumber`, so `as? Int` yielded 0/1 and a provider
	/// sending `{"used": true}` produced a confident, fabricated context reading.
	func testBooleanUsageValuesAreUnknownNotZeroOrOne() throws {
		let object = try JSONSerialization.jsonObject(
			with: Data(#"{"used":true,"size":false,"cost":true}"#.utf8)
		) as! [String: Any]
		let snapshot = OpenCodeUsageSnapshot.decode(usageObject: object, source: .usageUpdate)
		XCTAssertNil(snapshot.contextUsedTokens)
		XCTAssertNil(snapshot.contextWindowTokens)
		XCTAssertNil(snapshot.costAmount)
		XCTAssertTrue(snapshot.semanticProjection.isEmpty, "nothing was learned, so nothing may be emitted")
	}

	func testNegativeUsageValuesAreUnknownNotNegativeCounts() {
		let snapshot = OpenCodeUsageSnapshot.decode(
			usageObject: ["used": -5, "size": -1000, "inputTokens": -2, "cost": -0.5],
			source: .usageUpdate
		)
		XCTAssertNil(snapshot.contextUsedTokens)
		XCTAssertNil(snapshot.contextWindowTokens)
		XCTAssertNil(snapshot.inputTokens)
		XCTAssertNil(snapshot.costAmount)
	}

	/// NaN is never equal to itself, so a non-finite cost would make the dedup key
	/// compare unequal on every turn and emit an endless run of duplicate usage events.
	func testNonFiniteCostIsUnknownSoTheDedupKeyStaysStable() {
		let nan = OpenCodeUsageSnapshot.decode(usageObject: ["used": 1, "cost": Double.nan], source: .usageUpdate)
		let infinite = OpenCodeUsageSnapshot.decode(usageObject: ["used": 1, "cost": Double.infinity], source: .usageUpdate)
		XCTAssertNil(nan.costAmount)
		XCTAssertNil(infinite.costAmount)
		XCTAssertEqual(
			nan.semanticProjection,
			nan.semanticProjection,
			"the semantic key must be equal to itself — a NaN cost breaks exactly that"
		)
		XCTAssertEqual(nan.semanticProjection, infinite.semanticProjection)
	}

	func testNestedCostObjectAppliesTheSameValidation() {
		let snapshot = OpenCodeUsageSnapshot.decode(
			usageObject: ["cost": ["amount": Double.nan, "currency": "USD"]],
			source: .promptResponse
		)
		XCTAssertNil(snapshot.costAmount)
		XCTAssertEqual(snapshot.costCurrency, "USD", "currency is still evidence")
	}

	func testValidUsageValuesAreStillAccepted() {
		let snapshot = OpenCodeUsageSnapshot.decode(
			usageObject: ["used": 0, "size": 200_000, "cost": ["amount": 0.0, "currency": "USD"]],
			source: .usageUpdate
		)
		XCTAssertEqual(snapshot.contextUsedTokens, 0, "zero is a real reading, distinct from unknown")
		XCTAssertEqual(snapshot.contextWindowTokens, 200_000)
		XCTAssertEqual(snapshot.costAmount, 0.0)
	}

	// MARK: - Broader audit: key encoders are unambiguous too

	/// `agentName` comes straight off the wire from the runtime being keyed. With
	/// `name=value\n` framing, a newline in that value could forge a field boundary and
	/// make two different contracts share one key.
	func testContractKeyFramingResistsDelimiterInjectionInTheAdvertisedAgentName() {
		let digest = OpenCodeSHA256Digest.digest(ofUTF8: "caps")
		let honest = OpenCodeContractKey(input: OpenCodeContractKeyInput(
			acpProtocolVersion: 1,
			agentName: "OpenCode",
			capabilitySnapshotDigest: digest,
			usedSurfaceLockHash: nil
		))
		let forged = OpenCodeContractKey(input: OpenCodeContractKeyInput(
			acpProtocolVersion: 1,
			agentName: "OpenCode\ncapabilitySnapshotDigest=\(digest.value)",
			capabilitySnapshotDigest: digest,
			usedSurfaceLockHash: nil
		))
		XCTAssertNotEqual(honest.digest.value, forged.digest.value)
	}

	func testSingleSourceSnapshotIsNotReportedAsMixed() {
		var merged = OpenCodeUsageSnapshot.decode(usageObject: ["used": 0], source: .usageUpdate)
		for index in 1...20 {
			merged = merged.merging(latest: .decode(usageObject: ["used": index], source: .usageUpdate))
		}
		XCTAssertEqual(merged.contributingSources, [.usageUpdate])
		XCTAssertFalse(merged.isMixedSource)
	}
}

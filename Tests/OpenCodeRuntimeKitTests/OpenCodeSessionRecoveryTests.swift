import XCTest
@testable import OpenCodeRuntimeKit

final class OpenCodeSessionRecoveryTests: XCTestCase {
	private let sha = OpenCodeSHA256(String(repeating: "9a", count: 32))!
	private let otherSHA = OpenCodeSHA256(String(repeating: "1b", count: 32))!

	private func makeIdentity(sha: OpenCodeSHA256? = nil) -> OpenCodeRuntimeIdentity {
		OpenCodeRuntimeIdentity(
			resolvedPath: "/Users/dev/.opencode/bin/opencode",
			realPath: "/Users/dev/.opencode/bin/opencode",
			sha256: sha ?? self.sha,
			sizeBytes: 1000,
			modificationEpochSeconds: nil,
			architecture: .arm64,
			signingClass: .adHoc,
			pathClass: .openCodeManagedBin,
			cliVersion: OpenCodeCliVersion(string: "1.18.4")!
		)!
	}

	private func makeRecord(frontier: OpenCodeTranscriptFrontier = OpenCodeTranscriptFrontier()) -> OpenCodeSessionRecoveryRecord {
		OpenCodeSessionRecoveryRecord(
			providerSessionID: "ses_abc",
			canonicalRootPath: "/workspace/project",
			runtimeSHA256Hex: sha.value,
			cliVersion: "1.18.4",
			modelSelectionRaw: "anthropic/claude",
			sessionModeID: "repoprompt_acp",
			frontier: frontier
		)
	}

	private func capabilities(resume: Bool, load: Bool) -> OpenCodeEffectiveSessionCapabilities {
		OpenCodeEffectiveSessionCapabilities(
			appPolicy: OpenCodeCapabilitySnapshot.SessionCapabilities(
				loadSession: true, listSessions: true, resumeSession: true, closeSession: true, unstableForkSession: false
			),
			advertised: OpenCodeCapabilitySnapshot.SessionCapabilities(
				loadSession: load, listSessions: true, resumeSession: resume, closeSession: true, unstableForkSession: false
			)
		)
	}

	private func context(
		record: OpenCodeSessionRecoveryRecord?,
		rootPath: String = "/workspace/project",
		runtime: OpenCodeRuntimeResolution? = nil,
		decision: OpenCodeAdmissionDecision = .admitObserveOnly(.unknownRuntime),
		resume: Bool = true,
		load: Bool = true,
		attempts: Int = 0
	) -> OpenCodeSessionRecoveryContext {
		OpenCodeSessionRecoveryContext(
			record: record,
			currentCanonicalRootPath: rootPath,
			currentRuntime: runtime ?? .resolved(makeIdentity()),
			admissionDecision: decision,
			effectiveCapabilities: capabilities(resume: resume, load: load),
			recoveryAttemptsMade: attempts
		)
	}

	func testResumePreferredWhenAdvertised() {
		XCTAssertEqual(
			OpenCodeSessionRecoveryPlanner.plan(context(record: makeRecord())),
			.resume(sessionID: "ses_abc")
		)
	}

	func testLoadFallbackCarriesFrontierForDeduplication() {
		let frontier = OpenCodeTranscriptFrontier(seenMessageIDs: ["msg_1"], seenToolCallIDs: ["call_1"], lastEventOrdinal: 7)
		let plan = OpenCodeSessionRecoveryPlanner.plan(
			context(record: makeRecord(frontier: frontier), resume: false)
		)
		XCTAssertEqual(plan, .loadWithReplayDeduplication(sessionID: "ses_abc", frontier: frontier))
	}

	func testAtMostOneRecoveryAttempt() {
		XCTAssertEqual(
			OpenCodeSessionRecoveryPlanner.plan(context(record: makeRecord(), attempts: 1)),
			.refuse(.attemptAlreadyMade)
		)
	}

	func testRootChangeRefusesImplicitRebind() {
		XCTAssertEqual(
			OpenCodeSessionRecoveryPlanner.plan(context(record: makeRecord(), rootPath: "/workspace/other")),
			.refuse(.workspaceRootChanged(persisted: "/workspace/project", current: "/workspace/other"))
		)
	}

	func testUnresolvableRuntimeRefuses() {
		XCTAssertEqual(
			OpenCodeSessionRecoveryPlanner.plan(context(record: makeRecord(), runtime: .unresolvable(.commandNotFound))),
			.refuse(.runtimeUnresolvable(.commandNotFound))
		)
	}

	func testChangedBinaryRefusedUnderObserveOnlyAdmission() {
		let plan = OpenCodeSessionRecoveryPlanner.plan(
			context(
				record: makeRecord(),
				runtime: .resolved(makeIdentity(sha: otherSHA)),
				decision: .admitObserveOnly(.unknownRuntime)
			)
		)
		XCTAssertEqual(plan, .refuse(.runtimeNotAdmitted))
	}

	func testChangedBinaryRecoversWhenFreshAdmissionAdmitsIt() {
		let plan = OpenCodeSessionRecoveryPlanner.plan(
			context(
				record: makeRecord(),
				runtime: .resolved(makeIdentity(sha: otherSHA)),
				decision: .admitBehavioral(familyID: "stable-1.18.4")
			)
		)
		XCTAssertEqual(plan, .resume(sessionID: "ses_abc"))
	}

	func testRejectedRuntimeNeverRecovers() {
		XCTAssertEqual(
			OpenCodeSessionRecoveryPlanner.plan(
				context(record: makeRecord(), decision: .reject(.unknownRuntime))
			),
			.refuse(.runtimeNotAdmitted)
		)
	}

	func testNoCapabilityRefusesExplicitly() {
		XCTAssertEqual(
			OpenCodeSessionRecoveryPlanner.plan(context(record: makeRecord(), resume: false, load: false)),
			.refuse(.noRecoveryCapability)
		)
	}

	func testMissingRecordRefuses() {
		XCTAssertEqual(
			OpenCodeSessionRecoveryPlanner.plan(context(record: nil)),
			.refuse(.sessionIdentityMissing)
		)
	}

	// MARK: - Frontier

	func testFrontierDeduplicatesReplayedIdentifiers() {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "msg_1", toolCallID: nil)
		frontier = frontier.advanced(messageID: nil, toolCallID: "call_1")

		XCTAssertTrue(frontier.containsReplay(messageID: "msg_1", toolCallID: nil))
		XCTAssertTrue(frontier.containsReplay(messageID: nil, toolCallID: "call_1"))
		XCTAssertFalse(frontier.containsReplay(messageID: "msg_2", toolCallID: "call_2"))
		XCTAssertEqual(frontier.lastEventOrdinal, 2)
	}

	func testFrontierIsBounded() {
		var frontier = OpenCodeTranscriptFrontier()
		for index in 0..<(OpenCodeTranscriptFrontier.maxTrackedIdentifiers + 50) {
			frontier = frontier.advanced(messageID: "msg_\(index)", toolCallID: nil)
		}
		let roundTripped = OpenCodeTranscriptFrontier(
			seenMessageIDs: frontier.seenMessageIDs,
			seenToolCallIDs: frontier.seenToolCallIDs,
			lastEventOrdinal: frontier.lastEventOrdinal
		)
		XCTAssertLessThanOrEqual(roundTripped.seenMessageIDs.count, OpenCodeTranscriptFrontier.maxTrackedIdentifiers)
	}

	func testRecoveryRecordRoundTripsThroughCodable() throws {
		let record = makeRecord(
			frontier: OpenCodeTranscriptFrontier(seenMessageIDs: ["m"], seenToolCallIDs: ["t"], lastEventOrdinal: 3)
		)
		let data = try JSONEncoder().encode(record)
		let decoded = try JSONDecoder().decode(OpenCodeSessionRecoveryRecord.self, from: data)
		XCTAssertEqual(decoded, record)
	}

	func testFrontierAccumulatesObservedTextScalarCountPerMessage() {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "0123456789")
		frontier = frontier.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "abcde")
		frontier = frontier.advanced(messageID: "m2", toolCallID: nil, observedTextChunk: "xyz")

		XCTAssertEqual(frontier.observedTextScalarCount(forMessageID: "m1"), 15)
		XCTAssertEqual(frontier.observedTextScalarCount(forMessageID: "m2"), 3)
		XCTAssertNil(frontier.observedTextScalarCount(forMessageID: "m3"))
	}

	func testFrontierDigestIsChunkingIndependentContentEvidence() {
		var chunked = OpenCodeTranscriptFrontier()
		chunked = chunked.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "Hello, ")
		chunked = chunked.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "wor")
		var whole = OpenCodeTranscriptFrontier()
		whole = whole.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "Hello, wor")

		XCTAssertEqual(
			chunked.observedTextDigest(forMessageID: "m1"),
			whole.observedTextDigest(forMessageID: "m1"),
			"the digest must depend only on the cumulative text, not its chunking"
		)

		var different = OpenCodeTranscriptFrontier()
		different = different.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "Goodbye,xx")
		XCTAssertNotEqual(
			whole.observedTextDigest(forMessageID: "m1"),
			different.observedTextDigest(forMessageID: "m1"),
			"equal-length different content must produce different content evidence"
		)
	}

	func testFrontierMarksOverflowInsteadOfSilentlyForgettingIdentifiers() {
		var frontier = OpenCodeTranscriptFrontier()
		for index in 0..<OpenCodeTranscriptFrontier.maxTrackedIdentifiers {
			frontier = frontier.advanced(messageID: "m\(index)", toolCallID: nil)
		}
		XCTAssertFalse(frontier.didOverflow)
		XCTAssertTrue(frontier.containsReplay(messageID: "m0", toolCallID: nil), "identifiers within the bound must be retained, not evicted")

		frontier = frontier.advanced(messageID: "m-overflow", toolCallID: nil)
		XCTAssertTrue(
			frontier.didOverflow,
			"an identifier beyond the bound must mark the frontier overflowed — silent forgetting fails open into duplication"
		)
		XCTAssertTrue(frontier.containsReplay(messageID: "m0", toolCallID: nil), "overflow must not evict already-recorded identifiers")
	}

	func testFrontierTracksToolCallTerminalObservation() {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: nil, toolCallID: "t1")
		frontier = frontier.advanced(messageID: nil, toolCallID: "t2", toolCallReachedTerminal: true)

		XCTAssertFalse(frontier.sawTerminal(forToolCallID: "t1"), "a non-terminal observation must not claim the terminal was seen")
		XCTAssertTrue(frontier.sawTerminal(forToolCallID: "t2"))
		XCTAssertTrue(frontier.containsReplay(messageID: nil, toolCallID: "t1"))
	}

	func testFrontierDecodesLegacyPayloadWithoutChunkFields() throws {
		// A frontier persisted before the chunk-level fields existed: no
		// observedMessageTextScalarCounts / terminalToolCallIDs keys at all.
		let legacyJSON = #"{"seenMessageIDs":["m1"],"seenToolCallIDs":["t1"],"lastEventOrdinal":4}"#
		let decoded = try JSONDecoder().decode(OpenCodeTranscriptFrontier.self, from: Data(legacyJSON.utf8))

		XCTAssertEqual(decoded.seenMessageIDs, ["m1"])
		XCTAssertEqual(decoded.seenToolCallIDs, ["t1"])
		XCTAssertEqual(decoded.lastEventOrdinal, 4)
		XCTAssertNil(decoded.observedTextScalarCount(forMessageID: "m1"), "legacy records carry no length info; absence must be distinguishable")
		XCTAssertFalse(decoded.sawTerminal(forToolCallID: "t1"))
	}

	func testFrontierChunkFieldsRoundTripThroughCodable() throws {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: "t1", observedTextChunk: "twelve chars", toolCallReachedTerminal: true)
		let data = try JSONEncoder().encode(frontier)
		let decoded = try JSONDecoder().decode(OpenCodeTranscriptFrontier.self, from: data)
		XCTAssertEqual(decoded, frontier)
		XCTAssertEqual(decoded.observedTextScalarCount(forMessageID: "m1"), 12)
		XCTAssertEqual(decoded.observedTextDigest(forMessageID: "m1"), frontier.observedTextDigest(forMessageID: "m1"))
		XCTAssertFalse(decoded.didOverflow)
		XCTAssertTrue(decoded.sawTerminal(forToolCallID: "t1"))
	}
}

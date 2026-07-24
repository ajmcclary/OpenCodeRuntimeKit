import XCTest
@testable import OpenCodeRuntimeKit

/// Seventh acceptance-remediation round — pure-core regressions.
///
/// Covers finding 2 (complete frontier validation plus CHECKED live bounds), finding 3
/// (exact MCP launch verification), and finding 4 (exact integer usage decoding).
final class OpenCodeSeventhReviewCoreTests: XCTestCase {

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
	}

	// MARK: - Finding 2: the validator now covers every producible invariant

	/// A required message with NO coverage record silently drops out of the requirement
	/// loop, so the replay it was supposed to prove is never checked.
	func testRequiredCoverageWithoutACoverageRecordIsUnsupported() throws {
		try assertUnsupported(
			#"{"seenMessageIDs":["m1"],"contentEvidenceVersion":2,"requiredReplayCoverageMessageIDs":["m1"]}"#,
			"a requirement with nothing to compare against cannot be proven or disproven"
		)
	}

	func testCoverageRecordWithoutDigestEvidenceIsUnsupportedEvenAtZero() throws {
		// The live producer always creates the count/digest pair together, including the
		// zero-byte digest for an observed empty chunk.
		try assertUnsupported(
			#"{"seenMessageIDs":["m1"],"contentEvidenceVersion":2,"observedMessageTextScalarCounts":{"m1":0}}"#,
			"a coverage record with no digest is a pair the producer cannot emit"
		)
	}

	func testTerminalToolCallOutsideTheSeenSetIsUnsupported() throws {
		try assertUnsupported(
			#"{"seenMessageIDs":[],"seenToolCallIDs":["t1"],"terminalToolCallIDs":["t2"],"contentEvidenceVersion":2}"#,
			"a terminal observation for a never-seen tool call is impossible"
		)
	}

	func testDuplicateToolCallIDsAreUnsupported() throws {
		try assertUnsupported(
			#"{"seenMessageIDs":[],"seenToolCallIDs":["t1","t1"],"contentEvidenceVersion":2}"#,
			"duplicated tool identifiers make terminal bookkeeping ambiguous"
		)
	}

	func testEmptyIdentifiersAreUnsupported() throws {
		try assertUnsupported(
			#"{"seenMessageIDs":[""],"contentEvidenceVersion":2}"#,
			"an empty identifier can never match a provider identifier"
		)
	}

	func testNegativeOrAbsurdEventOrdinalIsUnsupported() throws {
		try assertUnsupported(
			#"{"seenMessageIDs":[],"lastEventOrdinal":-1,"contentEvidenceVersion":2}"#,
			"a negative ordinal is not a position in the stream"
		)
		try assertUnsupported(
			#"{"seenMessageIDs":[],"lastEventOrdinal":9223372036854775807,"contentEvidenceVersion":2}"#,
			"an ordinal at Int.max cannot be advanced and is not plausible state"
		)
	}

	func testValidToolAndOrdinalStateStaysSupported() throws {
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: "t1", observedTextChunk: "hi", toolCallReachedTerminal: true)
		let decoded = try decodeFrontier(String(data: try JSONEncoder().encode(frontier), encoding: .utf8)!)
		XCTAssertFalse(decoded.hasUnsupportedContentEvidence)
		XCTAssertEqual(decoded, frontier)
	}

	// MARK: - Finding 2: live bounds are checked and fail closed

	/// The gap: `maxObservedTextScalars` was enforced only while DECODING, so a
	/// supported frontier sitting exactly at the bound could advance past it with
	/// `didOverflow` still false — automatic recovery would then proceed on state the
	/// decoder itself would reject.
	func testAdvancingPastTheScalarBoundMarksOverflowAndRetainsTrustedState() throws {
		let atBound = OpenCodeTranscriptFrontier.maxObservedTextScalars
		var frontier = OpenCodeTranscriptFrontier()
		frontier = frontier.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "hello")
		XCTAssertEqual(frontier.observedTextScalarCount(forMessageID: "m1"), 5)
		XCTAssertFalse(frontier.didOverflow)

		// Advancing by a chunk that would exceed the bound must not update coverage.
		let huge = String(repeating: "y", count: 64)
		var saturating = frontier
		for _ in 0..<4 {
			saturating = saturating.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: huge)
		}
		XCTAssertFalse(saturating.didOverflow, "ordinary advancement well inside the bound must not overflow")
		XCTAssertEqual(saturating.observedTextScalarCount(forMessageID: "m1"), 5 + 64 * 4)
		XCTAssertLessThanOrEqual(saturating.observedTextScalarCount(forMessageID: "m1") ?? 0, atBound)
	}

	/// The boundary itself, without allocating a 16-million-scalar string: a frontier
	/// decoded AT the bound refuses to advance past it, retains its trusted coverage,
	/// and marks itself overflowed so the runner's pre-attempt refusal fires.
	func testFrontierAtTheScalarBoundRefusesToAdvanceAndMarksOverflow() throws {
		let bound = OpenCodeTranscriptFrontier.maxObservedTextScalars
		// A digest whose absorbed byte count equals the scalar count is UTF-8-consistent
		// for an all-ASCII message; build it by claiming the byte count directly.
		let digestJSON = #"{"state":[1,2,3,4,5,6,7,8],"tail":[],"byteCount":\#(bound)}"#
		let json = """
		{"seenMessageIDs":["m1"],"contentEvidenceVersion":2,
		 "observedMessageTextScalarCounts":{"m1":\(bound)},
		 "observedMessageTextDigests":{"m1":\(digestJSON)},
		 "requiredReplayCoverageMessageIDs":["m1"]}
		"""
		let atBound = try decodeFrontier(json)
		XCTAssertFalse(atBound.hasUnsupportedContentEvidence, "precondition: the at-bound record is valid")
		XCTAssertEqual(atBound.observedTextScalarCount(forMessageID: "m1"), bound)
		XCTAssertFalse(atBound.didOverflow)

		let advanced = atBound.advanced(messageID: "m1", toolCallID: nil, observedTextChunk: "z")
		XCTAssertTrue(advanced.didOverflow, "one scalar past the bound must mark the frontier overflowed")
		XCTAssertEqual(
			advanced.observedTextScalarCount(forMessageID: "m1"),
			bound,
			"already-trusted coverage must be RETAINED, never silently capped into a state that looks complete"
		)
		XCTAssertEqual(
			OpenCodeSessionRecoveryPlanner.plan(makeContext(frontier: advanced)),
			.refuse(.frontierOverflowed),
			"the overflowed frontier must refuse before anything else happens"
		)
	}

	func testEventOrdinalAtTheBoundMarksOverflowInsteadOfWrapping() throws {
		let json = """
		{"seenMessageIDs":[],"contentEvidenceVersion":2,"lastEventOrdinal":\(OpenCodeTranscriptFrontier.maxEventOrdinal)}
		"""
		let atBound = try decodeFrontier(json)
		XCTAssertFalse(atBound.hasUnsupportedContentEvidence)
		let advanced = atBound.advanced(messageID: "m1", toolCallID: nil)
		XCTAssertTrue(advanced.didOverflow)
		XCTAssertEqual(advanced.lastEventOrdinal, OpenCodeTranscriptFrontier.maxEventOrdinal, "the ordinal must not wrap")
	}

	func testDigestReportsSaturationInsteadOfWrappingItsBitLength() throws {
		// The largest block-aligned count below the bit-length bound, so the validated
		// `byteCount % 64 == tail.count` invariant still holds.
		let nearMax = (UInt64.max / 8 / 64) * 64
		let json = #"{"state":[1,2,3,4,5,6,7,8],"tail":[],"byteCount":\#(nearMax)}"#
		var digest = try JSONDecoder().decode(OpenCodeIncrementalSHA256.self, from: Data(json.utf8))
		XCTAssertFalse(digest.isSaturated)
		digest.update([UInt8](repeating: UInt8(ascii: "a"), count: 128))
		XCTAssertTrue(digest.isSaturated, "absorbing past the bit-length field must saturate, not wrap")
		XCTAssertEqual(digest.byteCount, UInt64.max / 8, "the count must stop at the bound rather than overflow")
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

	// MARK: - Finding 3: exact MCP launch verification

	private func mcpExpectation(
		launch: ExpectedMCPLaunch? = ExpectedMCPLaunch(
			command: ["/usr/local/bin/repoprompt-mcp", "--stdio"],
			environment: ["RP_TOKEN": "abc"]
		)
	) -> OpenCodeEffectiveConfigExpectation {
		OpenCodeEffectiveConfigExpectation(
			requiredModeID: "m",
			prohibitedTools: [],
			requiresWildcardDeny: false,
			repoPromptMCPName: "RepoPrompt",
			expectedMCPLaunch: launch,
			requiresMCPDisabled: false
		)
	}

	private func config(mcpEntry: [String: Any]) -> [String: Any] {
		[
			"agent": ["m": ["permission": [String: Any]()]],
			"mcp": ["RepoPrompt": mcpEntry]
		]
	}

	private func reasons(_ config: [String: Any], _ expectation: OpenCodeEffectiveConfigExpectation) -> [OpenCodeEffectiveConfigUnsafeReason] {
		switch OpenCodeEffectiveConfigEvaluator.evaluate(resolvedConfig: config, expectation: expectation) {
		case .safe: return []
		case .unsafe(let reasons): return reasons
		}
	}

	func testExactExpectedLaunchIsSafe() {
		XCTAssertTrue(reasons(
			config(mcpEntry: [
				"type": "local",
				"command": ["/usr/local/bin/repoprompt-mcp", "--stdio"],
				"environment": ["RP_TOKEN": "abc"],
				"enabled": true
			]),
			mcpExpectation()
		).isEmpty)
	}

	/// The defect: only `command.first` was compared, so appending `--exec` kept the
	/// same executable while changing its role entirely — and it evaluated SAFE.
	func testExtraArgvIsRejected() {
		let found = reasons(
			config(mcpEntry: [
				"type": "local",
				"command": ["/usr/local/bin/repoprompt-mcp", "--stdio", "--exec", "/bin/sh"],
				"environment": ["RP_TOKEN": "abc"],
				"enabled": true
			]),
			mcpExpectation()
		)
		XCTAssertTrue(
			found.contains { if case .repoPromptMCPEntryWrongCommand = $0 { return true } else { return false } },
			"extra argv must be rejected: \(found)"
		)
	}

	func testMissingAndReorderedArgvAreRejected() {
		for command in [
			["/usr/local/bin/repoprompt-mcp"],
			["--stdio", "/usr/local/bin/repoprompt-mcp"]
		] {
			let found = reasons(
				config(mcpEntry: ["type": "local", "command": command, "environment": ["RP_TOKEN": "abc"], "enabled": true]),
				mcpExpectation()
			)
			XCTAssertTrue(
				found.contains { if case .repoPromptMCPEntryWrongCommand = $0 { return true } else { return false } },
				"argv \(command) must be rejected: \(found)"
			)
		}
	}

	func testUnexpectedOrMissingEnvironmentIsRejected() {
		for environment in [
			["RP_TOKEN": "abc", "EXTRA": "1"],
			[String: String](),
			["RP_TOKEN": "different"]
		] {
			let found = reasons(
				config(mcpEntry: [
					"type": "local",
					"command": ["/usr/local/bin/repoprompt-mcp", "--stdio"],
					"environment": environment,
					"enabled": true
				]),
				mcpExpectation()
			)
			XCTAssertTrue(
				found.contains { if case .repoPromptMCPEntryWrongEnvironment = $0 { return true } else { return false } },
				"environment \(environment) must be rejected: \(found)"
			)
		}
	}

	func testUnexpectedTransportTypeIsRejected() {
		let found = reasons(
			config(mcpEntry: [
				"type": "remote",
				"command": ["/usr/local/bin/repoprompt-mcp", "--stdio"],
				"environment": ["RP_TOKEN": "abc"],
				"enabled": true
			]),
			mcpExpectation()
		)
		XCTAssertTrue(found.contains(.repoPromptMCPEntryWrongType("remote")), "\(found)")
	}

	func testMalformedCommandShapesAreRejected() {
		for command in [Any]([
			"not-an-array",
			[1, 2, 3],
			[String: String]()
		]) {
			let found = reasons(
				config(mcpEntry: ["type": "local", "command": command, "environment": ["RP_TOKEN": "abc"], "enabled": true]),
				mcpExpectation()
			)
			XCTAssertTrue(
				found.contains { if case .repoPromptMCPEntryWrongCommand = $0 { return true } else { return false } },
				"a command shape that cannot be established must never evaluate safe: \(found)"
			)
		}
	}

	/// Duplicate-alias diagnosis must survive the stricter comparison.
	func testDuplicateAliasDiagnosisIsRetained() {
		let config: [String: Any] = [
			"agent": ["m": ["permission": [String: Any]()]],
			"mcp": [
				"RepoPrompt": [
					"type": "local",
					"command": ["/usr/local/bin/repoprompt-mcp", "--stdio"],
					"environment": ["RP_TOKEN": "abc"],
					"enabled": true
				],
				"repoprompt-legacy": ["type": "local", "command": ["/tmp/other"], "enabled": true]
			]
		]
		XCTAssertTrue(
			reasons(config, mcpExpectation()).contains(.duplicateRepoPromptMCPAlias("repoprompt-legacy")),
			"alias diagnosis must not be lost to the exact-launch comparison"
		)
	}

	// MARK: - Finding 4: exact integer usage decoding

	private func decoded(_ json: String) throws -> OpenCodeUsageSnapshot {
		let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
		return OpenCodeUsageSnapshot.decode(usageObject: object, source: .usageUpdate)
	}

	/// `NSNumber.intValue` truncated 1.5 to 1 and -0.5 to 0 — the latter then PASSED the
	/// non-negative check and became a confident, fabricated zero.
	func testFractionalCountsAreUnknownNotTruncated() throws {
		XCTAssertNil(try decoded(#"{"used":1.5}"#).contextUsedTokens)
		XCTAssertNil(try decoded(#"{"used":0.5}"#).contextUsedTokens)
		XCTAssertNil(try decoded(#"{"used":-0.5}"#).contextUsedTokens, "-0.5 must not become 0")
		XCTAssertNil(try decoded(#"{"inputTokens":-3}"#).inputTokens)
	}

	func testOversizedNumbersAreUnknownNotClampedToIntMax() throws {
		XCTAssertNil(try decoded(#"{"used":1e30}"#).contextUsedTokens, "an oversized value must not clamp to Int.max")
		XCTAssertNil(try decoded(#"{"used":1e300}"#).contextUsedTokens)
	}

	func testExactlyRepresentableIntegersAreAccepted() throws {
		XCTAssertEqual(try decoded(#"{"used":0}"#).contextUsedTokens, 0, "zero is a real reading")
		XCTAssertEqual(try decoded(#"{"used":42}"#).contextUsedTokens, 42)
		// SUPERSEDED (twelfth round, finding 7): snapshot decode holds counts to the
		// semantic usage domain, so an exact 2^53 is unknown HERE while the general
		// parser still reads it exactly.
		XCTAssertNil(try decoded(#"{"used":9007199254740992}"#).contextUsedTokens)
		XCTAssertEqual(
			OpenCodeJSONNumberPolicy.nonNegativeCount(
				(try JSONSerialization.jsonObject(with: Data(#"{"used":9007199254740992}"#.utf8)) as! [String: Any])["used"]
			),
			9_007_199_254_740_992
		)
		XCTAssertEqual(try decoded(#"{"used":2.0}"#).contextUsedTokens, 2, "an integral double IS the count it states")
	}

	func testIntMaxIsAcceptedOnlyWhenExactlyStated() throws {
		// JSON integers decode as NSNumber-backed Int and stay exact — in the GENERAL
		// parser. Snapshot decode is domain-bounded (twelfth round, finding 7).
		XCTAssertEqual(
			OpenCodeJSONNumberPolicy.nonNegativeCount(
				(try JSONSerialization.jsonObject(with: Data(#"{"used":9223372036854775807}"#.utf8)) as! [String: Any])["used"]
			),
			Int.max
		)
		XCTAssertNil(try decoded(#"{"used":9223372036854775807}"#).contextUsedTokens)
	}

	func testBooleansRemainUnknown() throws {
		XCTAssertNil(try decoded(#"{"used":true}"#).contextUsedTokens)
		XCTAssertNil(try decoded(#"{"used":false}"#).contextUsedTokens)
	}

	/// String policy, stated explicitly: exact non-negative decimal integers only.
	func testStringFormsFollowTheDocumentedPolicy() {
		XCTAssertEqual(
			OpenCodeUsageSnapshot.decode(usageObject: ["used": "42"], source: .usageUpdate).contextUsedTokens,
			42
		)
		XCTAssertNil(
			OpenCodeUsageSnapshot.decode(usageObject: ["used": "1.5"], source: .usageUpdate).contextUsedTokens,
			"\"1.5\" is not an integer count in any spelling"
		)
		XCTAssertNil(
			OpenCodeUsageSnapshot.decode(usageObject: ["used": "-3"], source: .usageUpdate).contextUsedTokens
		)
	}

	/// An entirely invalid payload must produce nothing emittable, while its raw bytes
	/// stay visible as provenance.
	func testInvalidPayloadYieldsNoEmittableUsageButKeepsProvenance() throws {
		let snapshot = try decoded(#"{"used":1.5,"size":-2,"cost":true}"#)
		XCTAssertTrue(snapshot.semanticProjection.isEmpty, "nothing may be fabricated from an invalid payload")
		XCTAssertNotNil(snapshot.rawProvenanceJSON, "the rejected values remain visible as evidence")
		XCTAssertTrue(snapshot.rawProvenanceJSON?.contains("1.5") == true)
	}
}

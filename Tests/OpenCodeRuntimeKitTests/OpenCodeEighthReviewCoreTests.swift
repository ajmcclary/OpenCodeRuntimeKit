import XCTest
@testable import OpenCodeRuntimeKit

/// Eighth acceptance-remediation round — pure-core regressions.
///
/// Covers finding 3's planner half (a missing or malformed digest cannot prove
/// "unchanged"), finding 5 (exact integer usage decoding, including the rounded
/// floating boundary), and finding 6 (typed MCP environment / enabled shapes).
final class OpenCodeEighthReviewCoreTests: XCTestCase {

	// MARK: - Finding 3: absence of proof is not proof

	private let sha = OpenCodeSHA256(String(repeating: "9a", count: 32))!

	private func identity() -> OpenCodeRuntimeIdentity {
		OpenCodeRuntimeIdentity(
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
	}

	private func plan(
		recordedDigest: String?,
		decision: OpenCodeAdmissionDecision = .admitObserveOnly(.unknownRuntime)
	) -> OpenCodeSessionRecoveryPlan {
		OpenCodeSessionRecoveryPlanner.plan(OpenCodeSessionRecoveryContext(
			record: OpenCodeSessionRecoveryRecord(
				providerSessionID: "session-1",
				canonicalRootPath: "/tmp/ws",
				runtimeSHA256Hex: recordedDigest,
				cliVersion: "1.18.4",
				modelSelectionRaw: nil,
				sessionModeID: nil,
				frontier: OpenCodeTranscriptFrontier()
			),
			currentCanonicalRootPath: "/tmp/ws",
			currentRuntime: .resolved(identity()),
			admissionDecision: decision,
			effectiveCapabilities: OpenCodeEffectiveSessionCapabilities(
				appPolicy: .init(loadSession: true, listSessions: true, resumeSession: true, closeSession: true, unstableForkSession: false),
				advertised: .init(loadSession: true, listSessions: true, resumeSession: true, closeSession: true, unstableForkSession: false)
			),
			recoveryAttemptsMade: 0
		))
	}

	/// The defect: `bytesChanged` was computed only when a digest EXISTED, so a record
	/// with the digest omitted took the unchanged path and observe-only recovery
	/// proceeded against a binary nothing had verified.
	func testMissingRecordedDigestRefusesUnderObserveOnly() {
		XCTAssertEqual(plan(recordedDigest: nil), .refuse(.runtimeNotAdmitted))
	}

	func testMalformedRecordedDigestRefusesUnderObserveOnly() {
		for malformed in ["", "not-hex", String(repeating: "9a", count: 31), "zz" + String(repeating: "9a", count: 31)] {
			XCTAssertEqual(
				plan(recordedDigest: malformed),
				.refuse(.runtimeNotAdmitted),
				"a digest that cannot be parsed proves nothing: \(malformed)"
			)
		}
	}

	func testMatchingDigestStillResumesUnderObserveOnly() {
		XCTAssertEqual(plan(recordedDigest: sha.value), .resume(sessionID: "session-1"))
	}

	/// The existing policy is preserved: a genuinely changed runtime is still allowed
	/// when fresh admission explicitly grants it.
	func testExplicitAdmissionStillAllowsAChangedOrUnprovenRuntime() {
		XCTAssertEqual(
			plan(recordedDigest: nil, decision: .admitBehavioral(familyID: "stable-1.18.4")),
			.resume(sessionID: "session-1")
		)
		XCTAssertEqual(
			plan(recordedDigest: String(repeating: "1b", count: 32), decision: .admitCertified(familyID: "stable-1.18.4")),
			.resume(sessionID: "session-1")
		)
	}

	// MARK: - Finding 5: exact integer usage decoding

	private func decoded(_ json: String) throws -> OpenCodeUsageSnapshot {
		let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
		return OpenCodeUsageSnapshot.decode(usageObject: object, source: .usageUpdate)
	}

	private func parsedValue(_ json: String) throws -> Any? {
		let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
		return object["used"]
	}

	/// The boundary the seventh round got wrong: `JSONSerialization` parses
	/// 9007199254740993 into a floating value holding 9007199254740992, and checking
	/// `as? Int` first let that rounded number bridge cleanly and be accepted as exact.
	/// SUPERSEDED IN PART (twelfth round, finding 7): the exactness distinction is now
	/// pinned at the general parser (`nonNegativeCount`), because snapshot DECODE
	/// additionally applies the semantic usage domain — values this large are unknown
	/// there regardless of exactness.
	func testValuesThatRoundedIntoTheSafeBoundaryAreRejected() throws {
		XCTAssertEqual(
			OpenCodeJSONNumberPolicy.nonNegativeCount(try parsedValue(#"{"used":9007199254740991}"#)),
			9_007_199_254_740_991,
			"the general exact-count parser still accepts the exact integer"
		)
		XCTAssertNil(
			OpenCodeJSONNumberPolicy.nonNegativeCount(try parsedValue(#"{"used":9007199254740993.0}"#)),
			"a value Foundation already rounded is not evidence of the provider's count"
		)
		XCTAssertNil(OpenCodeJSONNumberPolicy.nonNegativeCount(try parsedValue(#"{"used":9.007199254740993e15}"#)))
		XCTAssertNil(
			OpenCodeJSONNumberPolicy.nonNegativeCount(try parsedValue(#"{"used":9007199254740992.0}"#)),
			"2^53 itself is ambiguous — an adjacent integer can round onto it"
		)
		XCTAssertNil(
			try decoded(#"{"used":9007199254740991}"#).contextUsedTokens,
			"snapshot decode holds even an exact reading to the semantic usage domain (twelfth round, finding 7)"
		)
	}

	/// Integer-backed JSON tokens are exact regardless of magnitude, so the GENERAL
	/// parser accepts them through a range-checked path rather than a floating one.
	/// SUPERSEDED IN PART (twelfth round, finding 7): snapshot decode no longer accepts
	/// them — a count near Int.max is not a context reading.
	func testIntegerTokensAreAcceptedExactly() throws {
		XCTAssertEqual(
			OpenCodeJSONNumberPolicy.nonNegativeCount(try parsedValue(#"{"used":9007199254740992}"#)),
			9_007_199_254_740_992
		)
		XCTAssertEqual(
			OpenCodeJSONNumberPolicy.nonNegativeCount(try parsedValue(#"{"used":9223372036854775807}"#)),
			Int.max
		)
		XCTAssertNil(try decoded(#"{"used":9007199254740992}"#).contextUsedTokens)
		XCTAssertNil(try decoded(#"{"used":9223372036854775807}"#).contextUsedTokens)
	}

	func testFractionalAndNegativeAndBooleanValuesRemainUnknown() throws {
		XCTAssertNil(try decoded(#"{"used":1.5}"#).contextUsedTokens)
		XCTAssertNil(try decoded(#"{"used":-0.5}"#).contextUsedTokens)
		XCTAssertNil(try decoded(#"{"used":-3}"#).contextUsedTokens)
		XCTAssertNil(try decoded(#"{"used":true}"#).contextUsedTokens)
		XCTAssertNil(try decoded(#"{"used":1e300}"#).contextUsedTokens)
	}

	/// The documented string grammar is ASCII decimal digits only. `Int(String)`
	/// accepts "+1", which made the previous statement of the policy untrue.
	func testStringGrammarIsASCIIDecimalDigitsOnly() {
		XCTAssertEqual(OpenCodeUsageSnapshot.decode(usageObject: ["used": "42"], source: .usageUpdate).contextUsedTokens, 42)
		XCTAssertEqual(OpenCodeUsageSnapshot.decode(usageObject: ["used": "0"], source: .usageUpdate).contextUsedTokens, 0)
		for rejected in ["+1", "-1", " 1", "1 ", "1_000", "1.0", "1e3", "", "١٢٣"] {
			XCTAssertNil(
				OpenCodeUsageSnapshot.decode(usageObject: ["used": rejected], source: .usageUpdate).contextUsedTokens,
				"the grammar must reject \(rejected)"
			)
		}
	}

	func testStringOverflowIsRejectedRatherThanClamped() {
		XCTAssertNil(
			OpenCodeUsageSnapshot.decode(
				usageObject: ["used": "99999999999999999999999"],
				source: .usageUpdate
			).contextUsedTokens
		)
	}

	// MARK: - Finding 6: typed MCP environment and enabled shapes

	private func expectation(
		launch: ExpectedMCPLaunch? = ExpectedMCPLaunch(command: ["/bin/mcp"], environment: [:])
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

	private func reasons(entry: [String: Any]) -> [OpenCodeEffectiveConfigUnsafeReason] {
		let config: [String: Any] = [
			"agent": ["m": ["permission": [String: Any]()]],
			"mcp": ["RepoPrompt": entry]
		]
		switch OpenCodeEffectiveConfigEvaluator.evaluate(resolvedConfig: config, expectation: expectation()) {
		case .safe: return []
		case .unsafe(let reasons): return reasons
		}
	}

	/// The defect: absent and malformed both normalized to `[:]`, which IS the
	/// production expectation, so `"environment":"malformed"` evaluated SAFE.
	func testMalformedEnvironmentShapesAreAlwaysUnsafe() {
		let malformedEnvironments: [Any] = ["malformed", ["a", "b"], 42, true]
		for malformed in malformedEnvironments {
			let found = reasons(entry: ["type": "local", "command": ["/bin/mcp"], "environment": malformed, "enabled": true])
			XCTAssertTrue(
				found.contains { if case .repoPromptMCPEntryMalformedEnvironment = $0 { return true } else { return false } },
				"environment \(malformed) must be malformed, never an empty map: \(found)"
			)
		}
	}

	func testNonStringEnvironmentValueIsMalformed() {
		let found = reasons(entry: [
			"type": "local", "command": ["/bin/mcp"], "environment": ["A": 1], "enabled": true
		])
		XCTAssertTrue(
			found.contains { if case .repoPromptMCPEntryMalformedEnvironment = $0 { return true } else { return false } },
			"\(found)"
		)
	}

	/// Measured against OpenCode 1.18.4: an explicitly written `"environment": {}` is
	/// PRESERVED in `debug config --pure` output, and the key is omitted only when the
	/// input omitted it. RepoPrompt's overlay always writes it, so absence means the
	/// entry is not the one RepoPrompt configured.
	func testAbsentEnvironmentIsNotEquivalentToAnExplicitEmptyMap() {
		let absent = reasons(entry: ["type": "local", "command": ["/bin/mcp"], "enabled": true])
		XCTAssertTrue(
			absent.contains { if case .repoPromptMCPEntryWrongEnvironment = $0 { return true } else { return false } },
			"\(absent)"
		)
		let explicit = reasons(entry: [
			"type": "local", "command": ["/bin/mcp"], "environment": [String: String](), "enabled": true
		])
		XCTAssertTrue(explicit.isEmpty, "a genuine empty object is the expected shape: \(explicit)")
	}

	/// A malformed `enabled` used to inherit the safe default silently.
	func testMalformedEnabledIsUnsafe() {
		let malformedEnabled: [Any] = ["yes", 1, ["true"]]
		for malformed in malformedEnabled {
			let found = reasons(entry: [
				"type": "local", "command": ["/bin/mcp"], "environment": [String: String](), "enabled": malformed
			])
			XCTAssertTrue(
				found.contains { if case .repoPromptMCPEntryMalformedEnabled = $0 { return true } else { return false } },
				"enabled \(malformed) must be malformed: \(found)"
			)
		}
	}

	func testAbsentEnabledKeepsTheDocumentedDefault() {
		let found = reasons(entry: ["type": "local", "command": ["/bin/mcp"], "environment": [String: String]()])
		XCTAssertTrue(found.isEmpty, "an entry with no `enabled` key is effective by default: \(found)")
	}

	/// Diagnostics must not print environment VALUES: a measured `debug config --pure`
	/// returns every configured MCP server, including third-party entries whose
	/// environments hold API keys.
	func testEnvironmentMismatchDiagnosticsRedactValues() {
		let found = reasons(entry: [
			"type": "local", "command": ["/bin/mcp"],
			"environment": ["TOKEN": "super-secret-value"], "enabled": true
		])
		let rendered = found.map(\.description).joined(separator: " ")
		XCTAssertTrue(rendered.contains("TOKEN"), "keys are useful diagnostics: \(rendered)")
		XCTAssertFalse(rendered.contains("super-secret-value"), "values must never be rendered: \(rendered)")
		XCTAssertFalse(
			rendered.contains("valuesDigest="),
			"a stable digest of secret values is still evidence about them (ninth round, finding 5): \(rendered)"
		)
	}
}

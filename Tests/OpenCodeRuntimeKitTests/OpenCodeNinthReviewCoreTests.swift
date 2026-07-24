import XCTest
@testable import OpenCodeRuntimeKit

/// Ninth acceptance-remediation round — pure-core regressions.
///
/// Covers finding 1's policy half, finding 2 (typed fail-closed capability decoding),
/// and finding 5 (resolved-config shape checking + secret-safe diagnostics).
///
/// Every provider-shaped fixture here is built from JSONSerialization-parsed BYTES, not
/// hand-built Swift dictionaries, so Foundation's NSNumber/Bool bridging — the thing
/// that made the previous decoding fail open — is actually exercised.
final class OpenCodeNinthReviewCoreTests: XCTestCase {

	private func parsed(_ json: String) throws -> [String: Any] {
		try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
	}

	// MARK: - Finding 1: one non-trapping number policy

	func testHostileNumbersAreUnknownAndNeverTrap() throws {
		let object = try parsed("""
		{"a":1e300,"b":-1e300,"c":1.5,"d":-1,"e":true,"f":false,
		 "g":9007199254740993.0,"h":9223372036854775807,"i":"+1","j":"01","k":"1e0","l":" 1"}
		""")
		for key in object.keys.sorted() where key != "h" {
			XCTAssertNil(
				OpenCodeJSONNumberPolicy.nonNegativeCount(object[key]),
				"\(key) must be unknown, never truncated/clamped/fabricated"
			)
		}
		XCTAssertEqual(OpenCodeJSONNumberPolicy.nonNegativeCount(object["h"]), Int.max, "an exact integer token is exact")
	}

	func testCanonicalSpellingsOnly() {
		XCTAssertEqual(OpenCodeJSONNumberPolicy.canonicalDecimalInteger("0"), 0)
		XCTAssertEqual(OpenCodeJSONNumberPolicy.canonicalDecimalInteger("42"), 42)
		XCTAssertEqual(OpenCodeJSONNumberPolicy.canonicalDecimalInteger("-7"), -7)
		for rejected in ["+1", "01", "-0", " 1", "1 ", "1e0", "1.0", "", "-", "١٢٣"] {
			XCTAssertNil(OpenCodeJSONNumberPolicy.canonicalDecimalInteger(rejected), "must reject \(rejected)")
		}
	}

	func testSafeIntegerBoundExcludesTwoToThe53() {
		XCTAssertEqual(OpenCodeJSONNumberPolicy.exactInteger(fromFinite: 9_007_199_254_740_991), 9_007_199_254_740_991)
		XCTAssertNil(
			OpenCodeJSONNumberPolicy.exactInteger(fromFinite: 9_007_199_254_740_992),
			"2^53 is where an adjacent integer can already have rounded on"
		)
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(fromFinite: .infinity))
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(fromFinite: .nan))
	}

	/// Rejected fields must not survive into a payload another parser will re-read.
	func testSanitizationStripsRejectedUsageFields() throws {
		let payload = try parsed(#"{"used":1e300,"size":200000,"cost":{"amount":-1,"currency":"USD"},"other":"kept"}"#)
		let sanitized = OpenCodeJSONNumberPolicy.sanitizedUsagePayload(payload)
		XCTAssertNil(sanitized["used"], "a rejected count must not be forwarded")
		XCTAssertNil(sanitized["cost"], "a rejected cost must not be forwarded")
		XCTAssertNotNil(sanitized["size"], "valid fields survive")
		XCTAssertNotNil(sanitized["other"], "non-numeric fields are untouched")
	}

	// MARK: - Finding 2: typed, fail-closed capability decoding

	/// The defect: parsed JSON `true` bridges to `Int(1)`, so this impersonated
	/// protocol version 1 and evaded the protocol-version safety invariant.
	func testBooleanProtocolVersionCannotImpersonateVersionOne() throws {
		let snapshot = OpenCodeCapabilitySnapshot.decode(
			initializeResponse: try parsed(#"{"protocolVersion":true,"agentCapabilities":{}}"#)
		)
		XCTAssertNotEqual(snapshot.protocolVersion, 1, "a boolean is not a protocol version")
		XCTAssertEqual(snapshot.protocolVersion, -1)
		XCTAssertTrue(
			snapshot.unknownCapabilityKeys.contains("malformed:protocolVersion"),
			"malformed protocol evidence must stay visible: \(snapshot.unknownCapabilityKeys)"
		)
	}

	func testMalformedProtocolVersionShapesAllFailClosed() throws {
		for raw in ["true", "false", "1.5", "9007199254740993.0", "\"one\"", "null", "[1]", "{\"v\":1}", "\"+1\"", "\"01\""] {
			let snapshot = OpenCodeCapabilitySnapshot.decode(
				initializeResponse: try parsed("{\"protocolVersion\":\(raw),\"agentCapabilities\":{}}")
			)
			XCTAssertNotEqual(snapshot.protocolVersion, 1, "\(raw) must not become protocol version 1")
		}
	}

	func testGenuineProtocolVersionStillDecodes() throws {
		let snapshot = OpenCodeCapabilitySnapshot.decode(
			initializeResponse: try parsed(#"{"protocolVersion":1,"agentCapabilities":{}}"#)
		)
		XCTAssertEqual(snapshot.protocolVersion, 1)
		XCTAssertFalse(snapshot.unknownCapabilityKeys.contains("malformed:protocolVersion"))
	}

	/// The mirror defect: a numeric 1 bridged to `Bool(true)` and granted a capability.
	func testNumericAndStringCapabilityValuesDoNotGrant() throws {
		let snapshot = OpenCodeCapabilitySnapshot.decode(
			initializeResponse: try parsed("""
			{"protocolVersion":1,"agentCapabilities":{"loadSession":1,"sessionCapabilities":
			 {"resume":"yes","close":[],"list":0}}}
			""")
		)
		XCTAssertFalse(snapshot.sessionCapabilities.loadSession, "numeric 1 must not grant loadSession")
		XCTAssertFalse(snapshot.sessionCapabilities.resumeSession)
		XCTAssertFalse(snapshot.sessionCapabilities.closeSession)
		XCTAssertFalse(snapshot.sessionCapabilities.listSessions)
		XCTAssertTrue(
			snapshot.unknownCapabilityKeys.contains { $0.hasPrefix("malformed:") },
			"malformed capability shapes must stay visible: \(snapshot.unknownCapabilityKeys)"
		)
	}

	func testFalseAndNullAndAbsenceNeverGrant() throws {
		let snapshot = OpenCodeCapabilitySnapshot.decode(
			initializeResponse: try parsed("""
			{"protocolVersion":1,"agentCapabilities":{"loadSession":false,
			 "sessionCapabilities":{"resume":null}}}
			""")
		)
		XCTAssertFalse(snapshot.sessionCapabilities.loadSession)
		XCTAssertFalse(snapshot.sessionCapabilities.resumeSession)
		XCTAssertFalse(snapshot.sessionCapabilities.closeSession)
	}

	/// The documented shapes must still work: real booleans and the ACP object form.
	func testDocumentedBooleanAndObjectFormsStillGrant() throws {
		let snapshot = OpenCodeCapabilitySnapshot.decode(
			initializeResponse: try parsed("""
			{"protocolVersion":1,"agentCapabilities":{"loadSession":true,
			 "sessionCapabilities":{"list":{},"resume":{},"close":{}}}}
			""")
		)
		XCTAssertTrue(snapshot.sessionCapabilities.loadSession)
		XCTAssertTrue(snapshot.sessionCapabilities.listSessions)
		XCTAssertTrue(snapshot.sessionCapabilities.resumeSession)
		XCTAssertTrue(snapshot.sessionCapabilities.closeSession)
		XCTAssertFalse(snapshot.unknownCapabilityKeys.contains { $0.hasPrefix("malformed:") })
	}

	/// Malformed protocol evidence must reach the enforcing safety invariant.
	func testMalformedProtocolVersionIsASafetyViolationAtEnforcingStages() throws {
		let snapshot = OpenCodeCapabilitySnapshot.decode(
			initializeResponse: try parsed(#"{"protocolVersion":true,"agentCapabilities":{"loadSession":true}}"#)
		)
		let identity = OpenCodeRuntimeIdentity(
			resolvedPath: "/bin/opencode", realPath: "/bin/opencode",
			sha256: OpenCodeSHA256(String(repeating: "9a", count: 32))!,
			sizeBytes: 10, modificationEpochSeconds: nil,
			architecture: .arm64, signingClass: .adHoc, pathClass: .openCodeManagedBin,
			cliVersion: OpenCodeCliVersion(string: "1.18.4")!
		)!
		let coordinator = OpenCodeAdmissionCoordinator(manifest: .empty)
		let assessment = coordinator.evaluatePostInitialize(
			OpenCodePostInitializeQuery(
				identity: identity,
				launchProfileKey: OpenCodeLaunchProfileKey(digest: OpenCodeSHA256Digest.digest(ofUTF8: "profile")),
				contractKey: OpenCodeContractKey(digest: OpenCodeSHA256Digest.digest(ofUTF8: "contract")),
				capabilitySnapshot: snapshot,
				effectiveConfigVerdict: nil
			),
			stage: .enforceSafetyInvariants
		)
		if case .reject = assessment.decision {
			// Expected: the invariant sees -1, not a forged 1.
		} else {
			XCTFail("malformed protocol evidence must be rejected at enforcing stages, got \(assessment.decision)")
		}
	}

	// MARK: - Finding 5: resolved-config shapes and secret-safe diagnostics

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

	private func reasons(_ json: String, _ expectation: OpenCodeEffectiveConfigExpectation? = nil) throws -> [OpenCodeEffectiveConfigUnsafeReason] {
		switch OpenCodeEffectiveConfigEvaluator.evaluate(
			resolvedConfig: try parsed(json),
			expectation: expectation ?? self.expectation()
		) {
		case .safe: return []
		case .unsafe(let reasons): return reasons
		}
	}

	func testExplicitNullEnabledIsMalformedNotAbsent() throws {
		let found = try reasons("""
		{"agent":{"m":{"permission":{}}},
		 "mcp":{"RepoPrompt":{"type":"local","command":["/bin/mcp"],"environment":{},"enabled":null}}}
		""")
		XCTAssertTrue(
			found.contains { if case .repoPromptMCPEntryMalformedEnabled = $0 { return true } else { return false } },
			"an explicit null must not inherit the effective-by-default rule: \(found)"
		)
	}

	func testMalformedRootsAreUnsafe() throws {
		for (label, json) in [
			("mcp root", #"{"agent":{"m":{"permission":{}}},"mcp":"nope"}"#),
			("server root", #"{"agent":{"m":{"permission":{}}},"mcp":{},"server":"nope"}"#)
		] {
			let found = try reasons(json)
			XCTAssertTrue(
				found.contains { if case .malformedResolvedShape = $0 { return true } else { return false } },
				"\(label) must be unsafe when its shape cannot be established: \(found)"
			)
		}
	}

	func testMalformedServerFieldsAreUnsafe() throws {
		for field in ["\"hostname\":123", "\"mdns\":\"yes\"", "\"cors\":{}"] {
			let found = try reasons("""
			{"agent":{"m":{"permission":{}}},
			 "mcp":{"RepoPrompt":{"type":"local","command":["/bin/mcp"],"environment":{},"enabled":true}},
			 "server":{\(field)}}
			""")
			XCTAssertTrue(
				found.contains { if case .malformedResolvedShape = $0 { return true } else { return false } },
				"\(field) leaves constrained safety unproven and must be unsafe: \(found)"
			)
		}
	}

	func testWellFormedServerOverridesStillEvaluateAsBefore() throws {
		let found = try reasons("""
		{"agent":{"m":{"permission":{}}},
		 "mcp":{"RepoPrompt":{"type":"local","command":["/bin/mcp"],"environment":{},"enabled":true}},
		 "server":{"hostname":"0.0.0.0","mdns":true}}
		""")
		XCTAssertTrue(found.contains(.serverOverrideDetected("hostname=0.0.0.0")), "\(found)")
		XCTAssertTrue(found.contains(.serverOverrideDetected("mdns=true")), "\(found)")
	}

	/// A mismatched argv is attacker- or third-party-controlled and can carry secrets;
	/// the rendered refusal must contain structure only.
	func testMismatchedArgvAndEnvironmentNeverRenderSecrets() throws {
		let argvSecret = "sk-argv-9c1f2e7d4b6a"
		let envSecret = "bearer-env-3f8a1c0d5e2b"
		let found = try reasons("""
		{"agent":{"m":{"permission":{}}},
		 "mcp":{"RepoPrompt":{"type":"local",
		   "command":["/opt/tools/mcp-bridge","--token=\(argvSecret)","\(argvSecret)"],
		   "environment":{"RP_TOKEN":"\(envSecret)"},"enabled":true}}}
		""")
		let rendered = found.map(\.description).joined(separator: " | ")
		XCTAssertFalse(rendered.isEmpty, "the mismatch must be reported")
		XCTAssertFalse(rendered.contains(argvSecret), "argv values must never be rendered: \(rendered)")
		XCTAssertFalse(rendered.contains(envSecret), "environment values must never be rendered: \(rendered)")
		XCTAssertTrue(rendered.contains("exe=mcp-bridge"), "structural information is still useful: \(rendered)")
		XCTAssertTrue(rendered.contains("RP_TOKEN"), "environment KEYS are still useful: \(rendered)")
		XCTAssertTrue(rendered.contains("--token"), "option NAMES are still useful: \(rendered)")
	}
}

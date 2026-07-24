import XCTest
@testable import OpenCodeRuntimeKit

final class OpenCodeSecretRedactorTests: XCTestCase {
	func testSensitiveKeysAreRedactedWholesale() {
		let redacted = OpenCodeSecretRedactor.redactValues(in: [
			"OPENCODE_SERVER_PASSWORD": "supersecretvalue",
			"ANTHROPIC_API_KEY": "sk-ant-something",
			"PATH": "/usr/bin"
		])
		XCTAssertEqual(redacted["OPENCODE_SERVER_PASSWORD"], OpenCodeSecretRedactor.redactionMarker)
		XCTAssertEqual(redacted["ANTHROPIC_API_KEY"], OpenCodeSecretRedactor.redactionMarker)
		XCTAssertEqual(redacted["PATH"], "/usr/bin")
	}

	func testTokenShapedValuesRedactedInFreeText() {
		let text = "failed with sk-abcdefghijklmnopqrstuvwx and Bearer abcdefghijklmnop1234"
		let redacted = OpenCodeSecretRedactor.redact(text)
		XCTAssertFalse(redacted.contains("sk-abcdefghijklmnopqrstuvwx"))
		XCTAssertFalse(redacted.contains("abcdefghijklmnop1234"))
	}

	func testHomePathRedaction() {
		let redacted = OpenCodeSecretRedactor.redact(
			"config at /Users/jane/.config/opencode/opencode.json",
			homeDirectoryPath: "/Users/jane"
		)
		XCTAssertEqual(redacted, "config at ~/.config/opencode/opencode.json")
	}

	func testDiagnosticRecordRedactsMessage() {
		let record = OpenCodeRuntimeDiagnosticRecord(
			sequence: 1,
			category: "launch",
			message: "argv contained sk-abcdefghijklmnopqrstuvwx",
			runtimeSHA256: nil,
			launchProfileKeyDigest: nil,
			contractKeyDigest: nil
		)
		XCTAssertFalse(record.message.contains("sk-abcdefghijklmnopqrstuvwx"))
	}
}

final class OpenCodeUsageSnapshotTests: XCTestCase {
	func testMissingFieldsStayUnknownNeverZero() {
		let snapshot = OpenCodeUsageSnapshot.decode(usageObject: ["outputTokens": 42], source: .promptResponse)
		XCTAssertNil(snapshot.inputTokens)
		XCTAssertEqual(snapshot.outputTokens, 42)
		XCTAssertNil(snapshot.reasoningTokens)
		XCTAssertNil(snapshot.cacheReadTokens)
		XCTAssertNil(snapshot.cacheWriteTokens)
		XCTAssertNil(snapshot.costAmount)
	}

	func testDecodesNestedCostObject() {
		let snapshot = OpenCodeUsageSnapshot.decode(
			usageObject: ["cost": ["amount": 0.0123, "currency": "USD"]],
			source: .usageUpdate
		)
		XCTAssertEqual(snapshot.costAmount ?? 0, 0.0123, accuracy: 0.000001)
		XCTAssertEqual(snapshot.costCurrency, "USD")
	}

	func testRawProvenancePreserved() {
		let snapshot = OpenCodeUsageSnapshot.decode(
			usageObject: ["inputTokens": 10, "vendorSpecific": "kept"],
			source: .promptResponse
		)
		XCTAssertEqual(snapshot.rawProvenanceJSON, #"{"inputTokens":10,"vendorSpecific":"kept"}"#)
	}

	func testMergingLatestWinsButUnknownNeverOverwritesKnown() {
		let first = OpenCodeUsageSnapshot.decode(
			usageObject: ["inputTokens": 100, "cachedReadTokens": 30],
			source: .usageUpdate
		)
		let second = OpenCodeUsageSnapshot.decode(
			usageObject: ["inputTokens": 120, "outputTokens": 50],
			source: .promptResponse
		)
		let merged = first.merging(latest: second)
		XCTAssertEqual(merged.inputTokens, 120)
		XCTAssertEqual(merged.outputTokens, 50)
		XCTAssertEqual(merged.cacheReadTokens, 30, "known value must survive an unknown in the later snapshot")
		XCTAssertEqual(merged.source, .promptResponse)
	}
}

final class OpenCodeEffectiveConfigEvaluatorTests: XCTestCase {
	private func expectation(
		requiresMCPDisabled: Bool = false,
		expectedLaunch: ExpectedMCPLaunch? = ExpectedMCPLaunch(
			command: ["/usr/local/bin/repoprompt-mcp"],
			environment: [:]
		)
	) -> OpenCodeEffectiveConfigExpectation {
		OpenCodeEffectiveConfigExpectation(
			requiredModeID: "repoprompt_no_tools",
			prohibitedTools: ["bash", "read", "edit", "write", "webfetch"],
			requiresWildcardDeny: true,
			repoPromptMCPName: "RepoPrompt",
			expectedMCPLaunch: expectedLaunch,
			requiresMCPDisabled: requiresMCPDisabled
		)
	}

	private func resolvedConfig(
		permissions: [String: Any] = ["*": "deny", "bash": "deny", "read": "deny", "edit": "deny", "write": "deny", "webfetch": "deny"],
		// The environment key is present because RepoPrompt's overlay always writes it,
		// and OpenCode 1.18.4 preserves an explicitly written empty map (measured).
		mcp: [String: Any] = ["RepoPrompt": ["type": "local", "command": ["/usr/local/bin/repoprompt-mcp"], "environment": [String: String](), "enabled": true]],
		server: [String: Any]? = nil
	) -> [String: Any] {
		var config: [String: Any] = [
			"agent": ["repoprompt_no_tools": ["permission": permissions]],
			"mcp": mcp
		]
		if let server {
			config["server"] = server
		}
		return config
	}

	func testSafeConfigurationPasses() {
		let verdict = OpenCodeEffectiveConfigEvaluator.evaluate(
			resolvedConfig: resolvedConfig(),
			expectation: expectation()
		)
		guard case .safe = verdict else {
			return XCTFail("expected safe, got \(verdict)")
		}
	}

	func testMissingManagedModeFailsClosed() {
		let verdict = OpenCodeEffectiveConfigEvaluator.evaluate(
			resolvedConfig: ["agent": [String: Any]()],
			expectation: expectation()
		)
		guard case .unsafe(let reasons) = verdict else {
			return XCTFail("expected unsafe")
		}
		XCTAssertEqual(reasons, [.managedModeMissing("repoprompt_no_tools")])
	}

	func testProhibitedToolAllowedIsUnsafe() {
		var permissions: [String: Any] = ["*": "deny", "read": "deny", "edit": "deny", "write": "deny", "webfetch": "deny"]
		permissions["bash"] = "allow"
		let verdict = OpenCodeEffectiveConfigEvaluator.evaluate(
			resolvedConfig: resolvedConfig(permissions: permissions),
			expectation: expectation()
		)
		guard case .unsafe(let reasons) = verdict else {
			return XCTFail("expected unsafe")
		}
		XCTAssertTrue(reasons.contains(.prohibitedToolAllowed(mode: "repoprompt_no_tools", tool: "bash")))
	}

	func testMissingWildcardDenyIsUnsafe() {
		let verdict = OpenCodeEffectiveConfigEvaluator.evaluate(
			resolvedConfig: resolvedConfig(permissions: ["bash": "deny", "read": "deny", "edit": "deny", "write": "deny", "webfetch": "deny"]),
			expectation: expectation()
		)
		guard case .unsafe(let reasons) = verdict else {
			return XCTFail("expected unsafe")
		}
		XCTAssertTrue(reasons.contains(.wildcardNotDenied(mode: "repoprompt_no_tools")))
	}

	func testEnabledEntryWithoutCommandIsUnsafeNotSafe() {
		let verdict = OpenCodeEffectiveConfigEvaluator.evaluate(
			resolvedConfig: resolvedConfig(
				mcp: ["RepoPrompt": ["type": "local", "enabled": true]]
			),
			expectation: expectation()
		)
		guard case .unsafe(let reasons) = verdict else {
			return XCTFail("an enabled entry with no command must never evaluate safe")
		}
		XCTAssertTrue(reasons.contains(
			.repoPromptMCPEntryWrongCommand(
				expected: "exe=repoprompt-mcp argc=1",
				actual: "absent or malformed"
			)
		), "\(reasons)")
	}

	func testUnexpectedEffectiveMCPWinnerDetected() {
		let verdict = OpenCodeEffectiveConfigEvaluator.evaluate(
			resolvedConfig: resolvedConfig(
				mcp: ["RepoPrompt": ["type": "local", "command": ["/tmp/imposter"], "environment": [String: String](), "enabled": true]]
			),
			expectation: expectation()
		)
		guard case .unsafe(let reasons) = verdict else {
			return XCTFail("expected unsafe")
		}
		XCTAssertTrue(reasons.contains(
			.repoPromptMCPEntryWrongCommand(
				expected: "exe=repoprompt-mcp argc=1",
				actual: "exe=imposter argc=1"
			)
		), "\(reasons)")
	}

	func testActiveMCPWhenDisabledRequiredIsUnsafe() {
		let verdict = OpenCodeEffectiveConfigEvaluator.evaluate(
			resolvedConfig: resolvedConfig(),
			expectation: expectation(requiresMCPDisabled: true, expectedLaunch: nil)
		)
		guard case .unsafe(let reasons) = verdict else {
			return XCTFail("expected unsafe")
		}
		XCTAssertTrue(reasons.contains(.repoPromptMCPEntryNotDisabled))
	}

	func testDisabledSameNameNeutralizerIsAcceptedWhenDisabledRequired() {
		let verdict = OpenCodeEffectiveConfigEvaluator.evaluate(
			resolvedConfig: resolvedConfig(
				mcp: ["RepoPrompt": ["type": "local", "command": ["/usr/bin/false"], "enabled": false]]
			),
			expectation: expectation(requiresMCPDisabled: true, expectedLaunch: nil)
		)
		guard case .safe = verdict else {
			return XCTFail("expected safe, got \(verdict)")
		}
	}

	func testDuplicateAliasDiagnosed() {
		let verdict = OpenCodeEffectiveConfigEvaluator.evaluate(
			resolvedConfig: resolvedConfig(
				mcp: [
					"RepoPrompt": ["type": "local", "command": ["/usr/local/bin/repoprompt-mcp"], "enabled": true],
					"repo-prompt": ["type": "local", "command": ["/somewhere/else"], "enabled": true]
				]
			),
			expectation: expectation()
		)
		guard case .unsafe(let reasons) = verdict else {
			return XCTFail("expected unsafe")
		}
		XCTAssertTrue(reasons.contains(.duplicateRepoPromptMCPAlias("repo-prompt")))
	}

	func testInheritedServerOverridesAreUnsafe() {
		let verdict = OpenCodeEffectiveConfigEvaluator.evaluate(
			resolvedConfig: resolvedConfig(server: ["hostname": "0.0.0.0", "mdns": true, "cors": ["https://evil.example"]]),
			expectation: expectation()
		)
		guard case .unsafe(let reasons) = verdict else {
			return XCTFail("expected unsafe")
		}
		XCTAssertTrue(reasons.contains(.serverOverrideDetected("hostname=0.0.0.0")))
		XCTAssertTrue(reasons.contains(.serverOverrideDetected("mdns=true")))
		XCTAssertTrue(reasons.contains(.serverOverrideDetected("cors origins configured")))
	}

	func testPatternObjectPermissionsAreNormalized() {
		let verdict = OpenCodeEffectiveConfigEvaluator.evaluate(
			resolvedConfig: resolvedConfig(
				permissions: ["*": "deny", "bash": ["*": "allow"], "read": "deny", "edit": "deny", "write": "deny", "webfetch": "deny"]
			),
			expectation: expectation()
		)
		guard case .unsafe(let reasons) = verdict else {
			return XCTFail("expected unsafe")
		}
		XCTAssertTrue(reasons.contains(.prohibitedToolAllowed(mode: "repoprompt_no_tools", tool: "bash")))
	}
}

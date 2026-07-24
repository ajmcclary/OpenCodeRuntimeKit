import XCTest
@testable import OpenCodeRuntimeKit

final class OpenCodeAdmissionEnforcementTests: XCTestCase {
	func testStageParsingAcceptsNamesAndNumbers() {
		XCTAssertEqual(OpenCodeAdmissionEnforcementStage(overrideValue: "observeOnly"), .observeOnly)
		XCTAssertEqual(OpenCodeAdmissionEnforcementStage(overrideValue: "2"), .enforceSafetyInvariants)
		XCTAssertNil(OpenCodeAdmissionEnforcementStage(overrideValue: "9"))
		XCTAssertNil(OpenCodeAdmissionEnforcementStage(overrideValue: "bogus"))
	}

	func testOverrideClassification() {
		XCTAssertEqual(OpenCodeEnforcementOverride(rawValue: nil), .absent)
		XCTAssertEqual(OpenCodeEnforcementOverride(rawValue: "  "), .absent)
		XCTAssertEqual(OpenCodeEnforcementOverride(rawValue: "enforceAll"), .valid(.enforceAll))
		XCTAssertEqual(OpenCodeEnforcementOverride(rawValue: "garbage"), .malformed)
	}

	func testResolutionPrecedenceFirstNonAbsentWins() {
		XCTAssertEqual(
			OpenCodeAdmissionEnforcementResolution.resolve(
				debug: .valid(.enforceAll), managed: .valid(.observeOnly), buildTimeShipping: .observeOnly
			),
			.enforceAll
		)
		XCTAssertEqual(
			OpenCodeAdmissionEnforcementResolution.resolve(
				debug: .absent, managed: .valid(.enforceKnownBad), buildTimeShipping: .enforceAll
			),
			.enforceKnownBad
		)
		XCTAssertEqual(
			OpenCodeAdmissionEnforcementResolution.resolve(
				debug: .absent, managed: .absent, buildTimeShipping: .enforceSafetyInvariants
			),
			.enforceSafetyInvariants
		)
	}

	func testMalformedOverrideFailsSafeToObserveOnlyWithoutFallthrough() {
		XCTAssertEqual(
			OpenCodeAdmissionEnforcementResolution.resolve(
				debug: .malformed, managed: .valid(.enforceAll), buildTimeShipping: .enforceAll
			),
			.observeOnly
		)
	}

	func testShippingStageIsObserveOnly() {
		XCTAssertEqual(OpenCodeAdmissionEnforcementResolution.shippingStage, .observeOnly)
	}
}

final class OpenCodeAdmissionCoordinatorTests: XCTestCase {
	private let binarySHA = OpenCodeSHA256(String(repeating: "9a", count: 32))!
	private let profileKey = OpenCodeLaunchProfileKey(digest: OpenCodeSHA256Digest.digest(ofUTF8: "profile"))
	private let contractKey = OpenCodeContractKey(digest: OpenCodeSHA256Digest.digest(ofUTF8: "contract"))

	private func makeIdentity(version: String = "1.18.4", sha: OpenCodeSHA256? = nil) -> OpenCodeRuntimeIdentity {
		OpenCodeRuntimeIdentity(
			resolvedPath: "/Users/dev/.opencode/bin/opencode",
			realPath: "/Users/dev/.opencode/bin/opencode",
			sha256: sha ?? binarySHA,
			sizeBytes: 138_295_010,
			modificationEpochSeconds: 1_784_559_734,
			architecture: .arm64,
			signingClass: .adHoc,
			pathClass: .openCodeManagedBin,
			cliVersion: OpenCodeCliVersion(string: version)!
		)!
	}

	private func makeManifest(
		certifiedSHA: OpenCodeSHA256? = nil,
		knownBad: [OpenCodeKnownBadRule] = []
	) -> OpenCodeCompatibilityManifest {
		let rows: [OpenCodeCertifiedEvidenceRow]
		if let certifiedSHA {
			rows = [OpenCodeCertifiedEvidenceRow(
				sha256: certifiedSHA,
				cliVersion: OpenCodeCliVersion(string: "1.18.4")!,
				architecture: .arm64,
				launchProfileKey: profileKey,
				contractKey: contractKey,
				acceptanceID: "acc-1",
				provenance: .installedBinary,
				limitations: []
			)]
		} else {
			rows = []
		}
		return OpenCodeCompatibilityManifest(
			schemaVersion: 1,
			manifestVersion: "test",
			families: [OpenCodeManifestFamily(
				id: "stable",
				classification: .supported,
				cliVersionRange: OpenCodeCliVersionRange(
					lowerBound: OpenCodeCliVersion(string: "1.17.14")!,
					upperBound: OpenCodeCliVersion(string: "1.18.4")!
				)!,
				sessionCapabilities: OpenCodeCapabilitySnapshot.SessionCapabilities(
					loadSession: true, listSessions: true, resumeSession: true, closeSession: true, unstableForkSession: false
				),
				certifiedRows: rows
			)],
			knownBadRules: knownBad
		)
	}

	private func makeSnapshot(protocolVersion: Int = 1) -> OpenCodeCapabilitySnapshot {
		OpenCodeCapabilitySnapshot(
			protocolVersion: protocolVersion,
			agentInfo: .init(name: "opencode", version: "1.18.4"),
			authMethodIDs: ["opencode-login"],
			sessionCapabilities: .none,
			unknownCapabilityKeys: []
		)
	}

	// MARK: - Stage 0 inertness

	func testStageZeroIsInertForEveryClassification() {
		let coordinator = OpenCodeAdmissionCoordinator(manifest: makeManifest(
			knownBad: [OpenCodeKnownBadRule(match: .sha256(binarySHA), reason: "bad build")]
		))
		let assessment = coordinator.evaluatePrelaunch(
			OpenCodePrelaunchQuery(
				resolution: .resolved(makeIdentity()),
				launchProfileKey: profileKey,
				secureContractViolations: [.missingServerPassword]
			),
			stage: .observeOnly
		)
		guard case .admitObserveOnly = assessment.decision else {
			return XCTFail("Stage 0 must never reject; got \(assessment.decision)")
		}
		guard case .knownBad = assessment.classification else {
			return XCTFail("Classification must still be recorded")
		}
	}

	// MARK: - Known-bad precedence

	func testKnownBadPrecedesCertifiedIdentity() {
		let coordinator = OpenCodeAdmissionCoordinator(manifest: makeManifest(
			certifiedSHA: binarySHA,
			knownBad: [OpenCodeKnownBadRule(match: .sha256(binarySHA), reason: "regression")]
		))
		let assessment = coordinator.evaluatePrelaunch(
			OpenCodePrelaunchQuery(
				resolution: .resolved(makeIdentity()),
				launchProfileKey: profileKey,
				secureContractViolations: []
			),
			stage: .enforceKnownBad
		)
		XCTAssertEqual(assessment.decision, .reject(.knownBad("regression")))
	}

	// MARK: - Certified and behavioral admission

	func testCertifiedIdentityAdmits() {
		let coordinator = OpenCodeAdmissionCoordinator(manifest: makeManifest(certifiedSHA: binarySHA))
		let assessment = coordinator.evaluatePrelaunch(
			OpenCodePrelaunchQuery(
				resolution: .resolved(makeIdentity()),
				launchProfileKey: profileKey,
				secureContractViolations: []
			),
			stage: .enforceAll
		)
		XCTAssertEqual(assessment.decision, .admitCertified(familyID: "stable"))
	}

	func testNewFingerprintIsBehaviorallyAdmissibleWhenGatesPass() {
		// Same version family, different bytes: NOT rejected solely for digest absence.
		let newSHA = OpenCodeSHA256(String(repeating: "c3", count: 32))!
		let coordinator = OpenCodeAdmissionCoordinator(manifest: makeManifest(certifiedSHA: binarySHA))
		let assessment = coordinator.evaluatePostInitialize(
			OpenCodePostInitializeQuery(
				identity: makeIdentity(sha: newSHA),
				launchProfileKey: profileKey,
				contractKey: contractKey,
				capabilitySnapshot: makeSnapshot(),
				effectiveConfigVerdict: .safe(diagnostics: [])
			),
			stage: .enforceAll
		)
		XCTAssertEqual(assessment.decision, .admitBehavioral(familyID: "stable"))
	}

	func testSafetyInvariantViolationFailsClosedAtStageTwo() {
		let coordinator = OpenCodeAdmissionCoordinator(manifest: makeManifest(certifiedSHA: binarySHA))
		let assessment = coordinator.evaluatePostInitialize(
			OpenCodePostInitializeQuery(
				identity: makeIdentity(),
				launchProfileKey: profileKey,
				contractKey: contractKey,
				capabilitySnapshot: makeSnapshot(),
				effectiveConfigVerdict: .unsafe(reasons: [.repoPromptMCPEntryNotDisabled])
			),
			stage: .enforceSafetyInvariants
		)
		guard case .reject(.secureContractViolation) = assessment.decision else {
			return XCTFail("effective-config unsafety must fail closed at stage 2, got \(assessment.decision)")
		}
	}

	func testProtocolMismatchIsSafetyInvariant() {
		let coordinator = OpenCodeAdmissionCoordinator(manifest: makeManifest())
		let assessment = coordinator.evaluatePostInitialize(
			OpenCodePostInitializeQuery(
				identity: makeIdentity(),
				launchProfileKey: profileKey,
				contractKey: contractKey,
				capabilitySnapshot: makeSnapshot(protocolVersion: 2),
				effectiveConfigVerdict: nil
			),
			stage: .enforceSafetyInvariants
		)
		guard case .reject = assessment.decision else {
			return XCTFail("protocol mismatch must fail closed under enforcement")
		}
	}

	func testUnknownRuntimeRejectedOnlyAtEnforceAll() {
		let coordinator = OpenCodeAdmissionCoordinator(manifest: makeManifest())
		let query = OpenCodePrelaunchQuery(
			resolution: .resolved(makeIdentity(version: "3.0.0")),
			launchProfileKey: profileKey,
			secureContractViolations: []
		)

		guard case .admitObserveOnly = coordinator.evaluatePrelaunch(query, stage: .enforceSafetyInvariants).decision else {
			return XCTFail("unknown runtime must remain observational below enforceAll")
		}
		XCTAssertEqual(
			coordinator.evaluatePrelaunch(query, stage: .enforceAll).decision,
			.reject(.unknownRuntime)
		)
	}

	func testUnresolvableIdentityRejectedAtSafetyStage() {
		let coordinator = OpenCodeAdmissionCoordinator(manifest: makeManifest())
		let assessment = coordinator.evaluatePrelaunch(
			OpenCodePrelaunchQuery(
				resolution: .unresolvable(.commandNotFound),
				launchProfileKey: profileKey,
				secureContractViolations: []
			),
			stage: .enforceSafetyInvariants
		)
		XCTAssertEqual(assessment.decision, .reject(.unresolvableIdentity(.commandNotFound)))
	}

	func testPreviewFamilyNeverGrantsBehavioralAdmission() {
		let preview = OpenCodeCompatibilityManifest(
			schemaVersion: 1,
			manifestVersion: "test",
			families: [OpenCodeManifestFamily(
				id: "preview",
				classification: .preview,
				cliVersionRange: OpenCodeCliVersionRange(
					lowerBound: OpenCodeCliVersion(string: "1.19.0")!,
					upperBound: OpenCodeCliVersion(string: "1.99.0")!
				)!,
				sessionCapabilities: .none,
				certifiedRows: []
			)],
			knownBadRules: []
		)
		let coordinator = OpenCodeAdmissionCoordinator(manifest: preview)
		let assessment = coordinator.evaluatePrelaunch(
			OpenCodePrelaunchQuery(
				resolution: .resolved(makeIdentity(version: "1.19.5")),
				launchProfileKey: profileKey,
				secureContractViolations: []
			),
			stage: .enforceAll
		)
		XCTAssertEqual(assessment.decision, .reject(.unknownRuntime))
	}
}

final class OpenCodeObservationHistoryTests: XCTestCase {
	private func makeKey(build: String = "100") -> OpenCodeAdmissionObservation.Key {
		OpenCodeAdmissionObservation.Key(
			runtimeSHA256: OpenCodeSHA256Digest.digest(ofUTF8: "runtime"),
			launchProfileKey: OpenCodeLaunchProfileKey(digest: OpenCodeSHA256Digest.digest(ofUTF8: "profile")),
			contractKey: nil,
			manifestVersion: "test",
			appBuild: build,
			probeSchemaVersion: 1
		)
	}

	func testHistoryIsBounded() {
		var history = OpenCodeObservationHistory(capacity: 3)
		for index in 0..<5 {
			history.record(OpenCodeAdmissionObservation(
				key: makeKey(),
				classification: .unknownRuntime,
				observedAtEpochSeconds: index
			))
		}
		XCTAssertEqual(history.observations.count, 3)
		XCTAssertEqual(history.observations.first?.observedAtEpochSeconds, 2, "oldest entries evict first")
	}

	func testLookupRequiresExactKey() {
		var history = OpenCodeObservationHistory()
		history.record(OpenCodeAdmissionObservation(
			key: makeKey(build: "100"),
			classification: .unknownRuntime,
			observedAtEpochSeconds: 1
		))
		XCTAssertEqual(history.observations(matching: makeKey(build: "100")).count, 1)
		XCTAssertTrue(history.observations(matching: makeKey(build: "101")).isEmpty, "app-build mismatch must return nothing")
	}
}

import XCTest
// Deliberately NOT `@testable`: this suite is the promoted package's PUBLIC API
// contract. Every symbol it touches must be reachable by an ordinary consumer
// (RepoPrompt reaches them through the `OpenCodeRuntimeCore` re-export shim).
// The 255 behavior tests that moved with the code keep their `@testable` import
// because two of them reach package-internal helpers; this one must not, or it
// would stop proving anything about visibility.
import OpenCodeRuntimeKit

/// Public-API contract for OpenCodeRuntimeKit — the eighth migrate.md extraction
/// and the fourth (final) provider-runtime promotion of staged-plan step 5.
///
/// What this pins, beyond "it compiles":
///   * per-family VISIBILITY, so a family cannot quietly become internal;
///   * the CLOSED vocabularies and their persisted raw values, which are written
///     into the compatibility manifest, the session-recovery record, and the
///     admission-observation key;
///   * DOMAIN SEPARATION of the two compatibility key axes, which is the whole
///     reason they are distinct types;
///   * the FAIL-CLOSED manifest decoder and the conservative `.empty` stand-in;
///   * the shipping ENFORCEMENT POSTURE, which this extraction must not move;
///   * the boundary itself — the package validates an already-constructed launch
///     shape and never builds one, hashes without CryptoKit, and decodes without
///     Bundle/FileManager.
final class OpenCodeRuntimeKitPublicAPIContractTests: XCTestCase {

	// MARK: - Visibility (compile-time pins, one per family)

	private typealias IdentityFamily = (
		OpenCodeCliVersion, OpenCodeCliVersionRange, OpenCodeSHA256,
		OpenCodeRuntimeIdentity, OpenCodeRuntimeResolution,
		OpenCodeExecutableSigningClass, OpenCodeExecutablePathClass,
		OpenCodeExecutableArchitecture, OpenCodeRuntimeUnresolvableReason
	)
	private typealias CompatibilityKeyFamily = (
		OpenCodeTransportClass, OpenCodeListenerSecurityClass, OpenCodeToolProfileClass,
		OpenCodeOverlayClass, OpenCodeWorkingDirectoryClass, OpenCodeConfigDigest,
		OpenCodeLaunchProfileKeyInput, OpenCodeLaunchProfileKey,
		OpenCodeContractKeyInput, OpenCodeContractKey, OpenCodeSHA256Digest.Type
	)
	private typealias ManifestFamily = (
		OpenCodeCompatibilityManifest, OpenCodeManifestFamily, OpenCodeCertifiedEvidenceRow,
		OpenCodeFamilyClassification, OpenCodeEvidenceProvenance,
		OpenCodeKnownBadRule, OpenCodeKnownBadMatch, OpenCodeManifestDecodingError
	)
	private typealias AdmissionFamily = (
		OpenCodeAdmissionCoordinator, OpenCodePrelaunchQuery, OpenCodePostInitializeQuery,
		OpenCodeAdmissionClassification, OpenCodeAdmissionDecision, OpenCodeAdmissionRejectReason,
		OpenCodeAdmissionAssessment, OpenCodeAdmissionEnforcementStage,
		OpenCodeEnforcementOverride, OpenCodeAdmissionEnforcementResolution.Type,
		OpenCodeAdmissionObservation, OpenCodeObservationHistory
	)
	private typealias CapabilityFamily = (
		OpenCodeCapabilitySnapshot, OpenCodeCapabilitySnapshot.AgentInfo,
		OpenCodeCapabilitySnapshot.SessionCapabilities, OpenCodeEffectiveSessionCapabilities,
		OpenCodeEffectiveConfigEvaluator.Type, OpenCodeEffectiveConfigExpectation,
		OpenCodeEffectiveConfigVerdict, OpenCodeEffectiveConfigUnsafeReason, ExpectedMCPLaunch
	)
	private typealias WireFamily = (
		OpenCodeRawEventEnvelope, OpenCodeEnvelopeAccounting, OpenCodeEnvelopeDirection,
		OpenCodeEnvelopeKind, OpenCodeEnvelopeDisposition, OpenCodeSuppressionReason,
		OpenCodePartialToolInputAssembler, OpenCodeJSONNumberPolicy.Type,
		OpenCodeIncrementalSHA256
	)
	private typealias RecoveryFamily = (
		OpenCodeSessionRecoveryRecord, OpenCodeTranscriptFrontier, OpenCodeSessionRecoveryContext,
		OpenCodeSessionRecoveryPlan, OpenCodeSessionRecoveryPlanner.Type,
		OpenCodeRecoveryRefusalReason
	)
	private typealias DiagnosticsAndUsageFamily = (
		OpenCodeRuntimeDiagnosticRecord, OpenCodeSecretRedactor.Type,
		OpenCodeUsageSnapshot, OpenCodeUsageSnapshot.Source,
		OpenCodeUsageSnapshot.ProvenanceEntry, OpenCodeUsageSnapshot.SemanticProjection
	)
	private typealias LaunchContractFamily = (
		OpenCodeSecureLaunchContract.Type, OpenCodeSecureLaunchContract.Violation
	)

	// MARK: - Closed vocabularies and persisted raw values

	/// These raw values are written into the generated compatibility manifest and
	/// into persisted admission-observation keys. Widening a vocabulary is a
	/// deliberate act; silently renaming a case is a data-compatibility break.
	func testClosedVocabulariesKeepTheirCountsAndRawValues() {
		XCTAssertEqual(OpenCodeTransportClass.allCases.map(\.rawValue), ["acpStdio"])
		XCTAssertEqual(
			OpenCodeListenerSecurityClass.allCases.map(\.rawValue),
			["authenticatedLoopback", "unconstrained"])
		XCTAssertEqual(
			OpenCodeToolProfileClass.allCases.map(\.rawValue),
			["agentMode", "agentModeFullAccess", "headless", "noTools"])
		XCTAssertEqual(
			OpenCodeOverlayClass.allCases.map(\.rawValue),
			["managedWithActiveMCP", "managedWithDisabledMCP", "none"])
		XCTAssertEqual(
			OpenCodeWorkingDirectoryClass.allCases.map(\.rawValue),
			["workspaceRoot", "temporaryDirectory"])
		XCTAssertEqual(
			OpenCodeFamilyClassification.allCases.map(\.rawValue),
			["supported", "limited", "preview"])
		// Hyphenated wire spellings — these appear verbatim in the manifest JSON.
		XCTAssertEqual(
			OpenCodeEvidenceProvenance.allCases.map(\.rawValue),
			["synthetic", "deterministic-fake", "installed-binary", "credentialed-live"])
		XCTAssertEqual(OpenCodeExecutableSigningClass.allCases.count, 6)
		XCTAssertEqual(OpenCodeExecutablePathClass.allCases.count, 6)
		XCTAssertEqual(OpenCodeExecutableArchitecture.allCases.map(\.rawValue),
			["arm64", "x86_64", "universal", "unknown"])
		XCTAssertEqual(OpenCodeRuntimeUnresolvableReason.allCases.count, 8)
		XCTAssertEqual(OpenCodeSuppressionReason.allCases.count, 10)
	}

	// MARK: - Enforcement posture (must survive the promotion unchanged)

	/// The extraction is behavior-preserving: OpenCode admission still ships in
	/// stage 0. Promoting the enforcement stage is an app-policy decision made in
	/// a separately reviewed change, never a side effect of a package move.
	func testShippingEnforcementPostureIsObserveOnly() {
		XCTAssertEqual(OpenCodeAdmissionEnforcementResolution.shippingStage, .observeOnly)
		XCTAssertEqual(OpenCodeAdmissionEnforcementStage.observeOnly.rawValue, 0)
		XCTAssertEqual(
			OpenCodeAdmissionEnforcementStage.allCases,
			[.observeOnly, .enforceKnownBad, .enforceSafetyInvariants, .enforceAll])
		XCTAssertTrue(OpenCodeAdmissionEnforcementStage.observeOnly < .enforceAll)
		XCTAssertEqual(OpenCodeAdmissionEnforcementStage(overrideValue: " enforceAll "), .enforceAll)
		XCTAssertNil(OpenCodeAdmissionEnforcementStage(overrideValue: "enforceEverything"))
	}

	// MARK: - Compatibility keys: domain separation and digest shape

	/// Two distinct key types exist so the axes can never be swapped at a call
	/// site, and their canonical encodings are domain-separated so structurally
	/// similar inputs cannot collide across axes.
	func testCompatibilityKeyAxesAreDomainSeparatedAndDigestsAre64Hex() throws {
		let digest = try XCTUnwrap(OpenCodeSHA256(String(repeating: "a", count: 64)))
		let launchInput = OpenCodeLaunchProfileKeyInput(
			transport: .acpStdio,
			listenerSecurity: .authenticatedLoopback,
			toolProfile: .agentMode,
			overlay: .managedWithActiveMCP,
			workingDirectoryClass: .workspaceRoot,
			pureMode: true,
			overlayConfigDigest: OpenCodeConfigDigest(sha256: digest))
		let contractInput = OpenCodeContractKeyInput(
			acpProtocolVersion: 1,
			agentName: "opencode",
			capabilitySnapshotDigest: digest,
			usedSurfaceLockHash: nil)

		let launchKey = OpenCodeLaunchProfileKey(input: launchInput)
		let contractKey = OpenCodeContractKey(input: contractInput)

		XCTAssertEqual(launchKey.digest.value.count, 64)
		XCTAssertEqual(contractKey.digest.value.count, 64)
		XCTAssertNotEqual(launchKey.digest, contractKey.digest)
		XCTAssertTrue(launchKey.description.hasPrefix("launch-profile:"))
		XCTAssertTrue(contractKey.description.hasPrefix("contract:"))

		// Domain separation is carried in the canonical BYTES, not just the label:
		// both encodings open with the shared domain marker and then diverge on the
		// domain string, so no field arrangement can make the two axes collide.
		XCTAssertNotEqual(launchInput.canonicalBytes, contractInput.canonicalBytes)
		let launchEncoding = String(decoding: launchInput.canonicalBytes, as: UTF8.self)
		let contractEncoding = String(decoding: contractInput.canonicalBytes, as: UTF8.self)
		XCTAssertTrue(launchEncoding.contains("launch-profile.v1"), launchEncoding)
		XCTAssertTrue(contractEncoding.contains("contract.v1"), contractEncoding)
		XCTAssertFalse(launchEncoding.contains("contract.v1"), launchEncoding)

		// The framing itself is part of the contract: every field is prefixed by its
		// big-endian UInt64 byte length, so a value can never impersonate structure.
		// The encoding therefore opens with length(19) + "opencode-key-domain", not
		// with the marker text itself.
		let marker = Array("opencode-key-domain".utf8)
		var expectedOpening = withUnsafeBytes(of: UInt64(marker.count).bigEndian) { Array($0) }
		expectedOpening.append(contentsOf: marker)
		XCTAssertEqual(Array(launchInput.canonicalBytes.prefix(expectedOpening.count)), expectedOpening)
		XCTAssertEqual(Array(contractInput.canonicalBytes.prefix(expectedOpening.count)), expectedOpening)

		// Forgery resistance, concretely: `agentName` arrives off the wire from the
		// runtime being keyed. A newline in it must not be able to fabricate a field
		// boundary and collide with a different input.
		let honest = OpenCodeContractKeyInput(
			acpProtocolVersion: 1, agentName: "opencode",
			capabilitySnapshotDigest: digest, usedSurfaceLockHash: nil)
		let forging = OpenCodeContractKeyInput(
			acpProtocolVersion: 1, agentName: "opencode\ncapabilitySnapshotDigest\n",
			capabilitySnapshotDigest: digest, usedSurfaceLockHash: nil)
		XCTAssertNotEqual(
			OpenCodeContractKey(input: honest).digest,
			OpenCodeContractKey(input: forging).digest)

		// A key is reconstructible from a stored digest without re-deriving inputs.
		XCTAssertEqual(OpenCodeLaunchProfileKey(digest: launchKey.digest), launchKey)

		// Changing any one axis changes the key.
		let flipped = OpenCodeLaunchProfileKeyInput(
			transport: .acpStdio,
			listenerSecurity: .authenticatedLoopback,
			toolProfile: .agentMode,
			overlay: .managedWithActiveMCP,
			workingDirectoryClass: .workspaceRoot,
			pureMode: false,
			overlayConfigDigest: OpenCodeConfigDigest(sha256: digest))
		XCTAssertNotEqual(OpenCodeLaunchProfileKey(input: flipped), launchKey)
	}

	/// `OpenCodeSHA256` is a validated 64-lowercase-hex value, not a String alias.
	func testSHA256ValueRejectsMalformedAndUppercaseInput() {
		XCTAssertNil(OpenCodeSHA256("NOTAHASH"))
		XCTAssertNil(OpenCodeSHA256(String(repeating: "A", count: 64)))
		XCTAssertNil(OpenCodeSHA256(String(repeating: "a", count: 63)))
		XCTAssertNotNil(OpenCodeSHA256(String(repeating: "0", count: 64)))
	}

	// MARK: - Hashing without CryptoKit

	/// The package computes SHA-256 itself (the boundary gate forbids CryptoKit)
	/// because the incremental hasher's in-progress state must be persistable.
	/// FIPS 180-4 vector: SHA-256("abc").
	func testSHA256MatchesKnownVectorAndIncrementalEqualsOneShot() {
		let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
		XCTAssertEqual(OpenCodeSHA256Digest.digest(ofUTF8: "abc").value, expected)
		XCTAssertEqual(OpenCodeSHA256Digest.digest(of: Data("abc".utf8)).value, expected)

		var incremental = OpenCodeIncrementalSHA256()
		XCTAssertTrue(incremental.isEmpty)
		incremental.update(utf8: "a")
		incremental.update(utf8: "b")
		incremental.update(utf8: "c")
		XCTAssertFalse(incremental.isEmpty)
		XCTAssertFalse(incremental.isSaturated)
		XCTAssertEqual(incremental.finalizedHex(), expected)

		// Chunking-independence is the property replay reconciliation relies on.
		var wholeChunk = OpenCodeIncrementalSHA256()
		wholeChunk.update(utf8: "abc")
		XCTAssertEqual(wholeChunk, incremental)

		// And the in-progress state round-trips through Codable so it can be
		// persisted mid-stream — the reason CryptoKit.SHA256 was rejected.
		var partial = OpenCodeIncrementalSHA256()
		partial.update(utf8: "a")
		let encoded = try? JSONEncoder().encode(partial)
		let restored = try? JSONDecoder().decode(
			OpenCodeIncrementalSHA256.self, from: XCTUnwrap(encoded))
		var resumed = try? XCTUnwrap(restored)
		resumed?.update(utf8: "bc")
		XCTAssertEqual(resumed?.finalizedHex(), expected)
	}

	// MARK: - Manifest: fail-closed decoding, no Bundle/FileManager

	/// The app owns resource layout and hands this decoder `Data`. It must stay
	/// reachable and stay fail-closed through a module move.
	func testManifestDecoderIsFailClosedAndEmptyIsTheAppsConservativeStandIn() {
		XCTAssertEqual(OpenCodeCompatibilityManifest.expectedSchemaVersion, 1)
		XCTAssertThrowsError(try OpenCodeCompatibilityManifest.decode(from: Data("{}".utf8)))
		XCTAssertThrowsError(try OpenCodeCompatibilityManifest.decode(from: Data()))
		XCTAssertThrowsError(
			try OpenCodeCompatibilityManifest.decode(from: Data("not json".utf8)))
		// A well-formed envelope with no families still fails closed rather than
		// decoding to a permissive manifest.
		XCTAssertThrowsError(try OpenCodeCompatibilityManifest.decode(
			from: Data(#"{"schemaVersion":1,"manifestVersion":"1","families":[],"knownBadRules":[]}"#.utf8)))

		// `.empty` is the app's stand-in for an ABSENT manifest; the decoder never
		// produces it. Both must survive the promotion.
		XCTAssertTrue(OpenCodeCompatibilityManifest.empty.families.isEmpty)
		XCTAssertTrue(OpenCodeCompatibilityManifest.empty.knownBadRules.isEmpty)
	}

	// MARK: - Secure launch contract (validation only — never construction)

	/// The package validates a FINAL argv/environment pair. Construction of that
	/// argv is app-owned (`OpenCodeLaunchPlanBuilder`), which the boundary gate's
	/// R2/R5 rules enforce from the other side.
	func testSecureLaunchContractValidatesFinalArgvAndEnvironment() {
		XCTAssertEqual(OpenCodeSecureLaunchContract.requiredHostname, "127.0.0.1")
		XCTAssertEqual(OpenCodeSecureLaunchContract.requiredPortArgument, "0")
		XCTAssertEqual(
			OpenCodeSecureLaunchContract.serverPasswordEnvironmentKey,
			"OPENCODE_SERVER_PASSWORD")
		XCTAssertEqual(OpenCodeSecureLaunchContract.minimumServerPasswordLength, 32)

		let password = String(repeating: "p", count: 40)
		let compliantArguments = [
			"acp", "--hostname", "127.0.0.1", "--port", "0", "--mdns", "false", "--pure"
		]
		let environment = [OpenCodeSecureLaunchContract.serverPasswordEnvironmentKey: password]

		XCTAssertEqual(
			OpenCodeSecureLaunchContract.validate(
				arguments: compliantArguments, environment: environment),
			[])

		// Wrong subcommand short-circuits.
		XCTAssertEqual(
			OpenCodeSecureLaunchContract.validate(arguments: ["serve"], environment: environment),
			[.missingACPSubcommand])

		// A non-loopback hostname is a violation even when everything else holds.
		let offLoopback = [
			"acp", "--hostname", "0.0.0.0", "--port", "0", "--mdns", "false", "--pure"
		]
		XCTAssertTrue(
			OpenCodeSecureLaunchContract
				.validate(arguments: offLoopback, environment: environment)
				.contains(.nonLoopbackHostname("0.0.0.0")))

		// The password reaches the child only via the environment.
		XCTAssertTrue(
			OpenCodeSecureLaunchContract
				.validate(arguments: compliantArguments, environment: [:])
				.contains(.missingServerPassword))
		XCTAssertTrue(
			OpenCodeSecureLaunchContract
				.validate(
					arguments: compliantArguments,
					environment: [OpenCodeSecureLaunchContract.serverPasswordEnvironmentKey: "short"])
				.contains(.weakServerPassword))
		XCTAssertTrue(
			OpenCodeSecureLaunchContract
				.validate(arguments: compliantArguments + [password], environment: environment)
				.contains(.serverPasswordInArguments))

		// Security-weakening and auto-approval flags are never acceptable.
		XCTAssertTrue(
			OpenCodeSecureLaunchContract
				.validate(arguments: compliantArguments + ["--share"], environment: environment)
				.contains(.unexpectedSecurityFlag("--share")))
		XCTAssertTrue(
			OpenCodeSecureLaunchContract
				.validate(arguments: compliantArguments + ["--auto"], environment: environment)
				.contains(.autoApprovalFlag("--auto")))
	}

	// MARK: - JSON number policy (the one policy for untrusted wire numbers)

	/// `Int(someDouble)` TRAPS outside `Int`'s range; a legal provider payload
	/// carrying `1e300` used to abort the host process. This policy is the single
	/// owner of that conversion and must stay public through the boundary.
	func testJSONNumberPolicyRejectsOutOfRangeAndNeverTreatsBooleansAsNumbers() {
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(1e300))
		XCTAssertNil(OpenCodeJSONNumberPolicy.boundedUsageCount(1e300))
		XCTAssertNil(OpenCodeJSONNumberPolicy.nonNegativeCount(-1))
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(1.5))
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(Double.nan))
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(Double.infinity))
		XCTAssertEqual(OpenCodeJSONNumberPolicy.exactInteger(42), 42)
		XCTAssertEqual(OpenCodeJSONNumberPolicy.exactInteger(42.0), 42)

		// A JSON boolean is never a number, even though Foundation bridges it to
		// NSNumber where `intValue` would fabricate 0/1.
		XCTAssertTrue(OpenCodeJSONNumberPolicy.isJSONBoolean(true))
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(true))
		XCTAssertNil(OpenCodeJSONNumberPolicy.boundedUsageCount(true))

		// An out-of-domain usage count is unknown, never a reading.
		XCTAssertNil(OpenCodeJSONNumberPolicy.boundedUsageCount(Int.max))
		XCTAssertEqual(OpenCodeJSONNumberPolicy.maxSafeIntegerInDouble, 9_007_199_254_740_991)
		XCTAssertEqual(OpenCodeJSONNumberPolicy.maxUsageTokenCount, 1_000_000_000_000)
	}

	// MARK: - Wire values

	func testCapabilitySnapshotDecodesInitializeEvidenceAndDigests() {
		let snapshot = OpenCodeCapabilitySnapshot.decode(initializeResponse: [
			"protocolVersion": 1,
			"agentInfo": ["name": "opencode", "version": "1.18.4"],
			"agentCapabilities": ["loadSession": true]
		])
		XCTAssertEqual(snapshot.protocolVersion, 1)
		XCTAssertEqual(snapshot.agentInfo?.name, "opencode")
		XCTAssertEqual(snapshot.digest.value.count, 64)
		// Unknown keys are RETAINED, not fatal, so drift stays visible.
		let drifted = OpenCodeCapabilitySnapshot.decode(initializeResponse: [
			"protocolVersion": 1,
			"agentCapabilities": ["somethingBrandNew": true]
		])
		XCTAssertTrue(drifted.unknownCapabilityKeys.contains("somethingBrandNew"))
		XCTAssertNotEqual(drifted.digest, snapshot.digest)

		// SessionCapabilities is Codable because it persists inside the recovery record.
		let none = OpenCodeCapabilitySnapshot.SessionCapabilities.none
		XCTAssertFalse(none.loadSession)
		let encoded = try? JSONEncoder().encode(none)
		XCTAssertNotNil(encoded)
	}

	func testPartialToolInputAssemblerAssemblesFragmentedInputThroughPublicAPI() {
		var assembler = OpenCodePartialToolInputAssembler()
		let key = OpenCodePartialToolInputAssembler.Key(sessionID: "s-1", toolCallID: "t-1")
		XCTAssertNil(assembler.ingest(
			key: key, toolName: "read", rawInput: ["path": "a.swift"],
			textFragment: "he", status: "pending"))
		let assembled = assembler.ingest(
			key: key, toolName: "read", rawInput: nil,
			textFragment: "llo", status: "completed")
		XCTAssertEqual(assembled?.key, key)
		XCTAssertEqual(assembled?.appendedText, "hello")
		XCTAssertEqual(assembled?.terminalState, .completed)
		XCTAssertEqual(assembled?.isIncomplete, false)
	}

	func testEnvelopeAccountingCountsEveryObservedEnvelope() {
		var accounting = OpenCodeEnvelopeAccounting()
		let envelope = OpenCodeRawEventEnvelope(
			sequence: 1,
			direction: .inbound,
			kind: .notification,
			method: "session/update",
			requestID: nil,
			sessionID: "s-1",
			sessionUpdateType: "agent_message_chunk",
			payloadByteCount: 42,
			disposition: .normalized(eventCount: 1))
		accounting.record(envelope)
		XCTAssertEqual(accounting.inboundTotal, 1)
		XCTAssertEqual(accounting.normalized, 1)
		XCTAssertTrue(accounting.isFullyAccounted)
		XCTAssertEqual(accounting.suppressedTotal, 0)
		XCTAssertEqual(accounting.unreasonedDrops, 0)

		// A drop WITHOUT one of the closed reasons is an accounting defect; a drop
		// WITH one is intentional and stays fully accounted.
		var suppressing = OpenCodeEnvelopeAccounting()
		suppressing.record(OpenCodeRawEventEnvelope(
			sequence: 1,
			direction: .inbound,
			kind: .notification,
			method: "session/update",
			requestID: nil,
			sessionID: "s-1",
			sessionUpdateType: "plan",
			payloadByteCount: 7,
			disposition: .suppressed(reason: .intentionallyUnsurfacedType)))
		XCTAssertEqual(suppressing.suppressedTotal, 1)
		XCTAssertTrue(suppressing.isFullyAccounted)

		XCTAssertEqual(OpenCodeEnvelopeDirection.inbound.rawValue, "inbound")
		XCTAssertEqual(OpenCodeEnvelopeKind.notification.rawValue, "notification")
	}

	func testUsageSnapshotDecodesThroughTheSharedNumberPolicy() {
		let snapshot = OpenCodeUsageSnapshot.decode(
			usageObject: ["input": 10, "output": 5, "cost": 0.25],
			source: .usageUpdate)
		XCTAssertEqual(snapshot.inputTokens, 10)
		XCTAssertEqual(snapshot.outputTokens, 5)
		XCTAssertEqual(snapshot.source, .usageUpdate)
		XCTAssertFalse(snapshot.isMixedSource)

		// The out-of-range value is refused as a reading but stays visible in the
		// provenance trail — the twelfth-round contract.
		let hostile = OpenCodeUsageSnapshot.decode(
			usageObject: ["input": 1e300], source: .usageUpdate)
		XCTAssertNil(hostile.inputTokens)
		XCTAssertFalse(hostile.provenanceTrail.isEmpty)
	}

	// MARK: - Recovery, diagnostics, redaction, observation history

	func testTranscriptFrontierAndRecoveryValuesArePubliclyConstructible() {
		let frontier = OpenCodeTranscriptFrontier(lastEventOrdinal: 0)
		XCTAssertEqual(frontier.lastEventOrdinal, 0)
		XCTAssertFalse(frontier.containsReplay(messageID: "m-1", toolCallID: nil))
		XCTAssertEqual(OpenCodeTranscriptFrontier.contentEvidenceVersion, 2)
		XCTAssertEqual(OpenCodeTranscriptFrontier.maxTrackedIdentifiers, 512)

		// The record is Codable because the APP persists it; the package owns only
		// the shape, never the store.
		let record = OpenCodeSessionRecoveryRecord(
			providerSessionID: "s-1",
			canonicalRootPath: "/tmp/ws",
			runtimeSHA256Hex: nil,
			cliVersion: "1.18.4",
			modelSelectionRaw: nil,
			sessionModeID: nil,
			frontier: frontier,
			lastSessionCapabilities: nil)
		let encoded = try? JSONEncoder().encode(record)
		XCTAssertNotNil(encoded)
	}

	func testSecretRedactorAndDiagnosticRecordSurviveThePromotion() {
		XCTAssertEqual(OpenCodeSecretRedactor.redactionMarker, "«redacted»")
		XCTAssertTrue(
			OpenCodeSecretRedactor.isSensitiveKey(
				OpenCodeSecureLaunchContract.serverPasswordEnvironmentKey))
		let redacted = OpenCodeSecretRedactor.redactValues(
			in: [OpenCodeSecureLaunchContract.serverPasswordEnvironmentKey: "hunter2", "PATH": "/usr/bin"])
		XCTAssertEqual(
			redacted[OpenCodeSecureLaunchContract.serverPasswordEnvironmentKey],
			OpenCodeSecretRedactor.redactionMarker)
		XCTAssertEqual(redacted["PATH"], "/usr/bin")

		let record = OpenCodeRuntimeDiagnosticRecord(
			sequence: 1,
			category: "admission",
			message: "observed",
			runtimeSHA256: nil,
			launchProfileKeyDigest: nil,
			contractKeyDigest: nil)
		XCTAssertEqual(record.category, "admission")
	}

	/// The package owns the bounded in-memory history VALUE; RepoPrompt owns any
	/// persistent observation store built on top of it.
	func testObservationHistoryIsBoundedAndQueryableByKey() throws {
		let sha = try XCTUnwrap(OpenCodeSHA256(String(repeating: "b", count: 64)))
		let key = OpenCodeAdmissionObservation.Key(
			runtimeSHA256: sha,
			launchProfileKey: OpenCodeLaunchProfileKey(digest: sha),
			contractKey: nil,
			manifestVersion: "1",
			appBuild: "test",
			probeSchemaVersion: 1)
		var history = OpenCodeObservationHistory(capacity: 2)
		XCTAssertEqual(history.capacity, 2)
		for index in 0..<3 {
			history.record(OpenCodeAdmissionObservation(
				key: key, classification: .unknownRuntime, observedAtEpochSeconds: index))
		}
		XCTAssertEqual(history.observations.count, 2)
		XCTAssertEqual(history.observations(matching: key).count, 2)
	}

	// MARK: - CLI version

	func testCliVersionParsesStrictlyAndOrdersNumerically() {
		XCTAssertEqual(OpenCodeCliVersion(string: "1.18.4"), OpenCodeCliVersion(major: 1, minor: 18, patch: 4))
		XCTAssertEqual(OpenCodeCliVersion(string: " 1.18.4 ")?.description, "1.18.4")
		XCTAssertNil(OpenCodeCliVersion(string: "1.18"))
		XCTAssertNil(OpenCodeCliVersion(string: "1.18.4-beta"))
		XCTAssertNil(OpenCodeCliVersion(string: "v1.18.4"))
		XCTAssertTrue(OpenCodeCliVersion(major: 1, minor: 2, patch: 0) < OpenCodeCliVersion(major: 1, minor: 10, patch: 0))

		let range = OpenCodeCliVersionRange(
			lowerBound: OpenCodeCliVersion(major: 1, minor: 0, patch: 0),
			upperBound: OpenCodeCliVersion(major: 2, minor: 0, patch: 0))
		XCTAssertNotNil(range)
		XCTAssertTrue(range?.contains(OpenCodeCliVersion(major: 1, minor: 18, patch: 4)) == true)
		// An inverted range is rejected at construction, not silently normalized.
		XCTAssertNil(OpenCodeCliVersionRange(
			lowerBound: OpenCodeCliVersion(major: 2, minor: 0, patch: 0),
			upperBound: OpenCodeCliVersion(major: 1, minor: 0, patch: 0)))
	}
}

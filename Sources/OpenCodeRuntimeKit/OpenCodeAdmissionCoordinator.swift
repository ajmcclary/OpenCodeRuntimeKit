import Foundation

// The sole admission classification/decision owner for OpenCode runtimes.
//
// Unlike Claude's exact-digest-only rule (which exists because Claude's behavior key is
// unavailable before a paid turn), OpenCode exposes pre-prompt probes: `--version`,
// `debug config --pure`, isolated ACP initialize, and the secure-listener contract. A
// newly fingerprinted binary may therefore be BEHAVIORALLY admitted when every supported
// pre-prompt gate passes. Known-bad matches and safety-invariant failures always fail
// closed at their enforcement stage.

/// Prelaunch phase input: identity and the final launch contract, before any child I/O.
public struct OpenCodePrelaunchQuery: Hashable, Sendable {
	public let resolution: OpenCodeRuntimeResolution
	public let launchProfileKey: OpenCodeLaunchProfileKey
	public let secureContractViolations: [OpenCodeSecureLaunchContract.Violation]

	public init(
		resolution: OpenCodeRuntimeResolution,
		launchProfileKey: OpenCodeLaunchProfileKey,
		secureContractViolations: [OpenCodeSecureLaunchContract.Violation]
	) {
		self.resolution = resolution
		self.launchProfileKey = launchProfileKey
		self.secureContractViolations = secureContractViolations
	}
}

/// Post-initialize phase input: what the runtime actually advertised plus the effective
/// configuration verdict, before the first provider prompt.
public struct OpenCodePostInitializeQuery: Hashable, Sendable {
	public let identity: OpenCodeRuntimeIdentity
	public let launchProfileKey: OpenCodeLaunchProfileKey
	public let contractKey: OpenCodeContractKey
	public let capabilitySnapshot: OpenCodeCapabilitySnapshot
	public let effectiveConfigVerdict: OpenCodeEffectiveConfigVerdict?

	public init(
		identity: OpenCodeRuntimeIdentity,
		launchProfileKey: OpenCodeLaunchProfileKey,
		contractKey: OpenCodeContractKey,
		capabilitySnapshot: OpenCodeCapabilitySnapshot,
		effectiveConfigVerdict: OpenCodeEffectiveConfigVerdict?
	) {
		self.identity = identity
		self.launchProfileKey = launchProfileKey
		self.contractKey = contractKey
		self.capabilitySnapshot = capabilitySnapshot
		self.effectiveConfigVerdict = effectiveConfigVerdict
	}
}

public enum OpenCodeAdmissionClassification: Hashable, Sendable {
	/// Byte-pinned certified row matched exactly.
	case certifiedIdentity(familyID: String)
	/// No certified row, but every supported pre-prompt gate passed and the version falls
	/// inside a supported family's range.
	case behaviorallyAdmissible(familyID: String)
	/// No family covers this runtime; observational only.
	case unknownRuntime
	case knownBad(reason: String)
	case safetyInvariantViolation(reasons: [String])
	case unresolvable(OpenCodeRuntimeUnresolvableReason)
}

public enum OpenCodeAdmissionRejectReason: Hashable, Sendable {
	case knownBad(String)
	case unresolvableIdentity(OpenCodeRuntimeUnresolvableReason)
	case secureContractViolation([String])
	case effectiveConfigUnsafe([String])
	case protocolMismatch(Int)
	case unknownRuntime
}

public enum OpenCodeAdmissionDecision: Hashable, Sendable {
	/// Stage 0: everything proceeds; the assessment is recorded, never enforced.
	case admitObserveOnly(OpenCodeAdmissionClassification)
	case admitCertified(familyID: String)
	case admitBehavioral(familyID: String)
	case reject(OpenCodeAdmissionRejectReason)
}

public struct OpenCodeAdmissionAssessment: Hashable, Sendable {
	public let classification: OpenCodeAdmissionClassification
	public let decision: OpenCodeAdmissionDecision
	public let stage: OpenCodeAdmissionEnforcementStage

	public init(
		classification: OpenCodeAdmissionClassification,
		decision: OpenCodeAdmissionDecision,
		stage: OpenCodeAdmissionEnforcementStage
	) {
		self.classification = classification
		self.decision = decision
		self.stage = stage
	}
}

public struct OpenCodeAdmissionCoordinator: Sendable {
	public let manifest: OpenCodeCompatibilityManifest

	public init(manifest: OpenCodeCompatibilityManifest) {
		self.manifest = manifest
	}

	// MARK: - Prelaunch

	public func evaluatePrelaunch(
		_ query: OpenCodePrelaunchQuery,
		stage: OpenCodeAdmissionEnforcementStage
	) -> OpenCodeAdmissionAssessment {
		let classification = classifyPrelaunch(query)
		let decision = decide(classification: classification, stage: stage)
		return OpenCodeAdmissionAssessment(classification: classification, decision: decision, stage: stage)
	}

	private func classifyPrelaunch(_ query: OpenCodePrelaunchQuery) -> OpenCodeAdmissionClassification {
		guard case .resolved(let identity) = query.resolution else {
			if case .unresolvable(let reason) = query.resolution {
				return .unresolvable(reason)
			}
			return .unresolvable(.noCommand)
		}

		if let knownBadReason = knownBadReason(identity: identity, contractKey: nil) {
			return .knownBad(reason: knownBadReason)
		}

		if !query.secureContractViolations.isEmpty {
			return .safetyInvariantViolation(reasons: query.secureContractViolations.map(\.description))
		}

		if let family = certifiedFamily(identity: identity, launchProfileKey: query.launchProfileKey) {
			return .certifiedIdentity(familyID: family.id)
		}
		if let family = versionFamily(for: identity.cliVersion) {
			// Behavioral admissibility is provisional at prelaunch; the post-initialize
			// phase confirms it against advertised capabilities and effective config.
			return .behaviorallyAdmissible(familyID: family.id)
		}
		return .unknownRuntime
	}

	// MARK: - Post-initialize

	public func evaluatePostInitialize(
		_ query: OpenCodePostInitializeQuery,
		stage: OpenCodeAdmissionEnforcementStage
	) -> OpenCodeAdmissionAssessment {
		let classification = classifyPostInitialize(query)
		let decision = decide(classification: classification, stage: stage)
		return OpenCodeAdmissionAssessment(classification: classification, decision: decision, stage: stage)
	}

	private func classifyPostInitialize(_ query: OpenCodePostInitializeQuery) -> OpenCodeAdmissionClassification {
		if let knownBadReason = knownBadReason(identity: query.identity, contractKey: query.contractKey) {
			return .knownBad(reason: knownBadReason)
		}

		var safetyFailures: [String] = []
		if query.capabilitySnapshot.protocolVersion != 1 {
			safetyFailures.append("unexpected ACP protocol version \(query.capabilitySnapshot.protocolVersion)")
		}
		if let verdict = query.effectiveConfigVerdict, case .unsafe(let reasons) = verdict {
			safetyFailures.append(contentsOf: reasons.map(\.description))
		}
		if !safetyFailures.isEmpty {
			return .safetyInvariantViolation(reasons: safetyFailures)
		}

		if let family = certifiedFamily(identity: query.identity, launchProfileKey: query.launchProfileKey) {
			return .certifiedIdentity(familyID: family.id)
		}
		if let family = versionFamily(for: query.identity.cliVersion) {
			return .behaviorallyAdmissible(familyID: family.id)
		}
		return .unknownRuntime
	}

	// MARK: - Decision

	private func decide(
		classification: OpenCodeAdmissionClassification,
		stage: OpenCodeAdmissionEnforcementStage
	) -> OpenCodeAdmissionDecision {
		// Stage 0 is fully inert: record, never reject.
		guard stage > .observeOnly else {
			return .admitObserveOnly(classification)
		}

		switch classification {
		case .knownBad(let reason):
			return .reject(.knownBad(reason))
		case .unresolvable(let reason):
			return stage >= .enforceSafetyInvariants
				? .reject(.unresolvableIdentity(reason))
				: .admitObserveOnly(classification)
		case .safetyInvariantViolation(let reasons):
			return stage >= .enforceSafetyInvariants
				? .reject(.secureContractViolation(reasons))
				: .admitObserveOnly(classification)
		case .certifiedIdentity(let familyID):
			return .admitCertified(familyID: familyID)
		case .behaviorallyAdmissible(let familyID):
			return .admitBehavioral(familyID: familyID)
		case .unknownRuntime:
			return stage >= .enforceAll
				? .reject(.unknownRuntime)
				: .admitObserveOnly(classification)
		}
	}

	// MARK: - Lookup helpers

	private func knownBadReason(identity: OpenCodeRuntimeIdentity, contractKey: OpenCodeContractKey?) -> String? {
		for rule in manifest.knownBadRules {
			switch rule.match {
			case .sha256(let sha) where sha == identity.sha256:
				return rule.reason
			case .contractKey(let key):
				if let contractKey, key == contractKey { return rule.reason }
			case .cliVersionRange(let range) where range.contains(identity.cliVersion):
				return rule.reason
			default:
				continue
			}
		}
		return nil
	}

	private func certifiedFamily(
		identity: OpenCodeRuntimeIdentity,
		launchProfileKey: OpenCodeLaunchProfileKey
	) -> OpenCodeManifestFamily? {
		manifest.families.first { family in
			family.certifiedRows.contains { row in
				row.sha256 == identity.sha256 && row.launchProfileKey == launchProfileKey
			}
		}
	}

	private func versionFamily(for version: OpenCodeCliVersion) -> OpenCodeManifestFamily? {
		manifest.families.first { family in
			family.classification != .preview && family.cliVersionRange.contains(version)
		}
	}
}

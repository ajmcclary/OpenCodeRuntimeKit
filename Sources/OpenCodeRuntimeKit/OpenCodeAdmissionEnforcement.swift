import Foundation

/// Staged rollout of admission enforcement.
///
/// Stage 0 (`observeOnly`) is inert: assessments are recorded but every launch proceeds.
/// Later stages are promoted only through separately reviewed policy changes. The secure
/// ACP listener/argv contract is NOT staged — it is construction-time behavior of the
/// launch plan and always applies.
public enum OpenCodeAdmissionEnforcementStage: Int, Hashable, Sendable, CaseIterable, Comparable {
	case observeOnly = 0
	case enforceKnownBad = 1
	case enforceSafetyInvariants = 2
	case enforceAll = 3

	public init?(overrideValue: String) {
		let trimmed = overrideValue.trimmingCharacters(in: .whitespacesAndNewlines)
		switch trimmed {
		case "observeOnly": self = .observeOnly
		case "enforceKnownBad": self = .enforceKnownBad
		case "enforceSafetyInvariants": self = .enforceSafetyInvariants
		case "enforceAll": self = .enforceAll
		default:
			guard let numeric = Int(trimmed),
				let stage = OpenCodeAdmissionEnforcementStage(rawValue: numeric)
			else { return nil }
			self = stage
		}
	}

	public static func < (lhs: OpenCodeAdmissionEnforcementStage, rhs: OpenCodeAdmissionEnforcementStage) -> Bool {
		lhs.rawValue < rhs.rawValue
	}
}

/// One override layer: absent yields to the next layer; malformed fails safe to
/// observe-only rather than inheriting a stricter lower-precedence stage.
public enum OpenCodeEnforcementOverride: Hashable, Sendable {
	case absent
	case valid(OpenCodeAdmissionEnforcementStage)
	case malformed

	public init(rawValue: String?) {
		guard let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			self = .absent
			return
		}
		if let stage = OpenCodeAdmissionEnforcementStage(overrideValue: rawValue) {
			self = .valid(stage)
		} else {
			self = .malformed
		}
	}
}

public enum OpenCodeAdmissionEnforcementResolution {
	/// Precedence: debug override, then managed override, then the build-time shipping
	/// stage. The first non-absent layer decides; a malformed layer resolves to
	/// observe-only without falling through (fail-safe, never fail-strict).
	public static func resolve(
		debug: OpenCodeEnforcementOverride,
		managed: OpenCodeEnforcementOverride,
		buildTimeShipping: OpenCodeAdmissionEnforcementStage
	) -> OpenCodeAdmissionEnforcementStage {
		switch debug {
		case .valid(let stage): return stage
		case .malformed: return .observeOnly
		case .absent: break
		}
		switch managed {
		case .valid(let stage): return stage
		case .malformed: return .observeOnly
		case .absent: break
		}
		return buildTimeShipping
	}

	/// The stage this build ships with. Stage 0 keeps the whole admission program
	/// observational and inert until promotion is separately reviewed.
	public static let shippingStage: OpenCodeAdmissionEnforcementStage = .observeOnly
}

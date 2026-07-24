import Foundation

/// Bounded, NON-AUTHORITATIVE admission observation history (NOW-1).
///
/// Observations diagnose drift and support decisions in the UI/support bundle. They can
/// never grant a capability, resume a session, or survive a mismatched identity/profile
/// as authority: every lookup requires the full key (identity + launch profile +
/// contract + manifest version + app build + probe schema) and the caller must still run
/// a fresh evaluation for the current runtime.
public struct OpenCodeAdmissionObservation: Hashable, Sendable {
	public struct Key: Hashable, Sendable {
		public let runtimeSHA256: OpenCodeSHA256
		public let launchProfileKey: OpenCodeLaunchProfileKey
		public let contractKey: OpenCodeContractKey?
		public let manifestVersion: String
		public let appBuild: String
		public let probeSchemaVersion: Int

		public init(
			runtimeSHA256: OpenCodeSHA256,
			launchProfileKey: OpenCodeLaunchProfileKey,
			contractKey: OpenCodeContractKey?,
			manifestVersion: String,
			appBuild: String,
			probeSchemaVersion: Int
		) {
			self.runtimeSHA256 = runtimeSHA256
			self.launchProfileKey = launchProfileKey
			self.contractKey = contractKey
			self.manifestVersion = manifestVersion
			self.appBuild = appBuild
			self.probeSchemaVersion = probeSchemaVersion
		}
	}

	public let key: Key
	public let classification: OpenCodeAdmissionClassification
	public let observedAtEpochSeconds: Int

	public init(
		key: Key,
		classification: OpenCodeAdmissionClassification,
		observedAtEpochSeconds: Int
	) {
		self.key = key
		self.classification = classification
		self.observedAtEpochSeconds = observedAtEpochSeconds
	}
}

/// FIFO-bounded observation store. Pure value semantics; persistence (if any) is
/// app-side and remains diagnostic-only.
public struct OpenCodeObservationHistory: Hashable, Sendable {
	public let capacity: Int
	public private(set) var observations: [OpenCodeAdmissionObservation] = []

	public init(capacity: Int = 128) {
		self.capacity = max(1, capacity)
	}

	public mutating func record(_ observation: OpenCodeAdmissionObservation) {
		observations.append(observation)
		if observations.count > capacity {
			observations.removeFirst(observations.count - capacity)
		}
	}

	/// Exact-key lookup for diagnostics. Any axis mismatch returns nothing — history can
	/// never be consulted through a weaker key.
	public func observations(matching key: OpenCodeAdmissionObservation.Key) -> [OpenCodeAdmissionObservation] {
		observations.filter { $0.key == key }
	}
}

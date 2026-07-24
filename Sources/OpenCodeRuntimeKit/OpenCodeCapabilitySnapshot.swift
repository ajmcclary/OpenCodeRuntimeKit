import Foundation

/// Decoded, retained ACP `initialize` evidence for one OpenCode runtime.
///
/// Unknown capability keys are preserved (retained, not fatal) so drift is visible
/// without breaking admission. The snapshot is pure data; the app-side controller
/// produces it from the raw initialize response.
public struct OpenCodeCapabilitySnapshot: Hashable, Sendable {
	public struct AgentInfo: Hashable, Sendable {
		public let name: String
		public let version: String

		public init(name: String, version: String) {
			self.name = name
			self.version = version
		}
	}

	/// Stable optional ACP session capabilities RepoPrompt understands. Codable so the
	/// last-observed set can persist inside the session recovery record.
	public struct SessionCapabilities: Hashable, Sendable, Codable {
		public let loadSession: Bool
		public let listSessions: Bool
		public let resumeSession: Bool
		public let closeSession: Bool
		/// OpenCode's fork remains an unstable-named method; tracked separately and never
		/// promoted to a stable capability by this snapshot.
		public let unstableForkSession: Bool

		public init(
			loadSession: Bool,
			listSessions: Bool,
			resumeSession: Bool,
			closeSession: Bool,
			unstableForkSession: Bool
		) {
			self.loadSession = loadSession
			self.listSessions = listSessions
			self.resumeSession = resumeSession
			self.closeSession = closeSession
			self.unstableForkSession = unstableForkSession
		}

		public static let none = SessionCapabilities(
			loadSession: false,
			listSessions: false,
			resumeSession: false,
			closeSession: false,
			unstableForkSession: false
		)
	}

	public let protocolVersion: Int
	public let agentInfo: AgentInfo?
	public let authMethodIDs: [String]
	public let sessionCapabilities: SessionCapabilities
	/// Capability keys advertised by the agent that RepoPrompt does not model. Sorted for
	/// deterministic digests.
	public let unknownCapabilityKeys: [String]

	public init(
		protocolVersion: Int,
		agentInfo: AgentInfo?,
		authMethodIDs: [String],
		sessionCapabilities: SessionCapabilities,
		unknownCapabilityKeys: [String]
	) {
		self.protocolVersion = protocolVersion
		self.agentInfo = agentInfo
		self.authMethodIDs = authMethodIDs
		self.sessionCapabilities = sessionCapabilities
		self.unknownCapabilityKeys = unknownCapabilityKeys.sorted()
	}

	/// Deterministic digest over the snapshot for contract-key derivation.
	public var digest: OpenCodeSHA256 {
		// Eleventh round, adjacent audit: a LIST joined with "," inside the otherwise
		// length-framed encoder reintroduces exactly the ambiguity the framing exists to
		// prevent — `["a", "b,c"]` and `["a,b", "c"]` both render `"a,b,c"`, so two
		// distinct capability advertisements could share a digest. Each list is emitted as
		// a framed count plus one framed field PER ELEMENT, so no element's content can
		// impersonate a list boundary.
		var fields: [(String, String)] = [
			("protocolVersion", String(protocolVersion)),
			("agentName", agentInfo?.name ?? "absent"),
			("agentVersion", agentInfo?.version ?? "absent"),
			("loadSession", sessionCapabilities.loadSession ? "1" : "0"),
			("listSessions", sessionCapabilities.listSessions ? "1" : "0"),
			("resumeSession", sessionCapabilities.resumeSession ? "1" : "0"),
			("closeSession", sessionCapabilities.closeSession ? "1" : "0"),
			("unstableForkSession", sessionCapabilities.unstableForkSession ? "1" : "0")
		]
		func appendList(_ name: String, _ elements: [String]) {
			fields.append(("\(name).count", String(elements.count)))
			for (index, element) in elements.enumerated() {
				fields.append(("\(name)[\(index)]", element))
			}
		}
		appendList("authMethods", authMethodIDs.sorted())
		appendList("unknownCapabilityKeys", unknownCapabilityKeys)
		return OpenCodeSHA256Digest.digest(of: OpenCodeCanonicalEncoder.encode(domain: "capability-snapshot.v1", fields: fields))
	}

	/// Decodes an ACP initialize response payload (already parsed into Foundation JSON
	/// containers by the app-side transport) into a typed snapshot. This is a decoding
	/// convenience, not a transport: no I/O.
	/// TYPED, FAIL-CLOSED decoding of provider-controlled initialize evidence
	/// (ninth round, finding 2). The previous body leaned on Foundation bridging, which
	/// is not type-preserving for JSON scalars: a parsed `true` casts to `Int(1)`, so a
	/// runtime advertising `"protocolVersion": true` impersonated protocol version 1 and
	/// slipped past the protocol-version safety invariant; a numeric `1` casts to
	/// `Bool(true)`; and ANY non-null capability value counted as advertised support.
	/// Every scalar is now decoded through an explicit representation check, and
	/// anything that is not one of the documented shapes fails closed — never granting,
	/// and recorded as malformed evidence so admission can see it.
	public static func decode(initializeResponse: [String: Any]) -> OpenCodeCapabilitySnapshot {
		var malformedKeys: [String] = []
		let rawProtocolVersion = initializeResponse["protocolVersion"]
		let protocolVersion: Int
		if rawProtocolVersion == nil {
			protocolVersion = -1
		} else if let decoded = OpenCodeJSONNumberPolicy.exactInteger(rawProtocolVersion) {
			protocolVersion = decoded
		} else {
			// A boolean, fraction, rounded float, malformed string, array, object, or
			// null must never become a protocol version.
			protocolVersion = -1
			malformedKeys.append("protocolVersion")
		}

		/// A container that is present but is not the documented shape is EVIDENCE — a
		/// runtime advertising `"agentCapabilities": []` is telling us something different
		/// from a runtime that advertises nothing at all. Tenth round, finding 7: both
		/// collapsed to `[:]` here, so malformed initialize evidence was indistinguishable
		/// from absence and never reached the contract digest or the admission
		/// observation. Absent and explicit-null stay absent (no key recorded); anything
		/// else present-but-wrong grants nothing AND is recorded as malformed.
		func shapedObject(_ raw: Any?, key: String) -> [String: Any] {
			guard let raw, !(raw is NSNull) else { return [:] }
			if let object = raw as? [String: Any] { return object }
			malformedKeys.append(key)
			return [:]
		}

		var agentInfo: AgentInfo?
		let agentInfoObject = shapedObject(initializeResponse["agentInfo"], key: "agentInfo")
		if let name = agentInfoObject["name"] as? String {
			let rawVersion = agentInfoObject["version"]
			if rawVersion != nil, !(rawVersion is NSNull), !(rawVersion is String) {
				malformedKeys.append("agentInfo.version")
			}
			agentInfo = AgentInfo(name: name, version: (rawVersion as? String) ?? "")
		} else if !agentInfoObject.isEmpty {
			// Present, object-shaped, but carrying no usable identity.
			malformedKeys.append("agentInfo.name")
		}

		let rawAuthMethods = initializeResponse["authMethods"]
		var authMethodIDs: [String] = []
		if let rawAuthMethods, !(rawAuthMethods is NSNull) {
			if let entries = rawAuthMethods as? [Any] {
				for entry in entries {
					guard let object = entry as? [String: Any], let id = object["id"] as? String else {
						malformedKeys.append("authMethods.entry")
						continue
					}
					authMethodIDs.append(id)
				}
			} else {
				malformedKeys.append("authMethods")
			}
		}

		let capabilities = shapedObject(initializeResponse["agentCapabilities"], key: "agentCapabilities")
		let knownTopLevelKeys: Set<String> = ["loadSession", "sessionCapabilities", "promptCapabilities", "mcpCapabilities"]

		let sessionCapabilitiesObject = shapedObject(capabilities["sessionCapabilities"], key: "sessionCapabilities")

		/// The documented advertisement shapes, and ONLY those: a real JSON boolean, or
		/// an object (ACP advertises some optional session capabilities as `list: {}`).
		/// A number, string, array, or null grants nothing and is recorded as malformed —
		/// previously any non-null value at all was read as "supported", so
		/// `"resume": 0` or `"resume": "no"` granted the capability.
		func shapedFlag(_ raw: Any?, key: String) -> Bool? {
			guard let raw, !(raw is NSNull) else { return nil }
			if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
				return number.boolValue
			}
			if raw is [String: Any] { return true }
			malformedKeys.append(key)
			return false
		}

		func sessionFlag(_ key: String) -> Bool {
			if let flat = shapedFlag(capabilities[key], key: key) { return flat }
			if let nested = shapedFlag(sessionCapabilitiesObject[key], key: "sessionCapabilities.\(key)") { return nested }
			return false
		}

		let sessionCapabilities = SessionCapabilities(
			loadSession: sessionFlag("loadSession"),
			listSessions: sessionFlag("list") || sessionFlag("listSessions"),
			resumeSession: sessionFlag("resume") || sessionFlag("resumeSession"),
			closeSession: sessionFlag("close") || sessionFlag("closeSession"),
			unstableForkSession: sessionFlag("unstable_forkSession") || sessionFlag("fork")
		)

		let knownSessionKeys: Set<String> = [
			"loadSession", "list", "listSessions", "resume", "resumeSession",
			"close", "closeSession", "fork", "unstable_forkSession"
		]
		var unknownKeys = capabilities.keys.filter { !knownTopLevelKeys.contains($0) && !knownSessionKeys.contains($0) }
		unknownKeys += sessionCapabilitiesObject.keys
			.filter { !knownSessionKeys.contains($0) }
			.map { "sessionCapabilities.\($0)" }

		// Malformed evidence stays VISIBLE: it enters the unknown-key set, so it reaches
		// the contract digest and the admission observation rather than being discarded.
		// Deduplicated and ordered so repeated malformed entries (several bad
		// `authMethods` elements, say) stay stable in the contract digest.
		unknownKeys += Set(malformedKeys).map { "malformed:\($0)" }.sorted()

		return OpenCodeCapabilitySnapshot(
			protocolVersion: protocolVersion,
			agentInfo: agentInfo,
			authMethodIDs: authMethodIDs,
			sessionCapabilities: sessionCapabilities,
			unknownCapabilityKeys: unknownKeys
		)
	}
}

/// Session-scoped effective capabilities: the intersection of what the app supports as
/// static policy, what the manifest certifies, and what the runtime advertises. The
/// intersection can narrow but never widen app policy, and a prior observation can never
/// grant a capability the current runtime does not advertise.
public struct OpenCodeEffectiveSessionCapabilities: Hashable, Sendable {
	public let loadSession: Bool
	public let listSessions: Bool
	public let resumeSession: Bool
	public let closeSession: Bool

	public init(
		appPolicy: OpenCodeCapabilitySnapshot.SessionCapabilities,
		certified: OpenCodeCapabilitySnapshot.SessionCapabilities,
		advertised: OpenCodeCapabilitySnapshot.SessionCapabilities
	) {
		self.loadSession = appPolicy.loadSession && certified.loadSession && advertised.loadSession
		self.listSessions = appPolicy.listSessions && certified.listSessions && advertised.listSessions
		self.resumeSession = appPolicy.resumeSession && certified.resumeSession && advertised.resumeSession
		self.closeSession = appPolicy.closeSession && certified.closeSession && advertised.closeSession
	}

	/// Behavioral-admission variant: when no manifest family certifies this runtime, the
	/// certified axis is treated as fully open and safety rests on app policy ∩
	/// advertisement. Fork is deliberately absent: it never becomes effective.
	public init(
		appPolicy: OpenCodeCapabilitySnapshot.SessionCapabilities,
		advertised: OpenCodeCapabilitySnapshot.SessionCapabilities
	) {
		self.loadSession = appPolicy.loadSession && advertised.loadSession
		self.listSessions = appPolicy.listSessions && advertised.listSessions
		self.resumeSession = appPolicy.resumeSession && advertised.resumeSession
		self.closeSession = appPolicy.closeSession && advertised.closeSession
	}
}

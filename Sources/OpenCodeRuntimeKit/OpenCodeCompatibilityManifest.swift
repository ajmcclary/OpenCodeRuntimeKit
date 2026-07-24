import Foundation

// Closed, fail-closed compatibility-manifest decoding.
//
// The manifest is generated from reviewed evidence (Scripts/OpenCode) rather than edited
// by hand. Decoding rejects unexpected properties, malformed hashes, unknown enum
// members, inverted version ranges, and duplicate certified rows. The decoder never
// touches Bundle or FileManager — the app owns resource layout; the core owns decoding.

public enum OpenCodeFamilyClassification: String, Hashable, Sendable, CaseIterable {
	case supported
	case limited
	case preview
}

/// One byte-pinned certified evidence row: an exact executable identity measured under an
/// exact launch profile against an exact contract.
public struct OpenCodeCertifiedEvidenceRow: Hashable, Sendable {
	public let sha256: OpenCodeSHA256
	public let cliVersion: OpenCodeCliVersion
	public let architecture: OpenCodeExecutableArchitecture
	public let launchProfileKey: OpenCodeLaunchProfileKey
	public let contractKey: OpenCodeContractKey
	public let acceptanceID: String
	public let provenance: OpenCodeEvidenceProvenance
	public let limitations: [String]

	public init(
		sha256: OpenCodeSHA256,
		cliVersion: OpenCodeCliVersion,
		architecture: OpenCodeExecutableArchitecture,
		launchProfileKey: OpenCodeLaunchProfileKey,
		contractKey: OpenCodeContractKey,
		acceptanceID: String,
		provenance: OpenCodeEvidenceProvenance,
		limitations: [String]
	) {
		self.sha256 = sha256
		self.cliVersion = cliVersion
		self.architecture = architecture
		self.launchProfileKey = launchProfileKey
		self.contractKey = contractKey
		self.acceptanceID = acceptanceID
		self.provenance = provenance
		self.limitations = limitations
	}
}

/// Honest provenance labels; a deterministic fake can never be promoted to live evidence.
public enum OpenCodeEvidenceProvenance: String, Hashable, Sendable, CaseIterable {
	case synthetic
	case deterministicFake = "deterministic-fake"
	case installedBinary = "installed-binary"
	case credentialedLive = "credentialed-live"
}

public struct OpenCodeManifestFamily: Hashable, Sendable {
	public let id: String
	public let classification: OpenCodeFamilyClassification
	public let cliVersionRange: OpenCodeCliVersionRange
	public let sessionCapabilities: OpenCodeCapabilitySnapshot.SessionCapabilities
	public let certifiedRows: [OpenCodeCertifiedEvidenceRow]

	public init(
		id: String,
		classification: OpenCodeFamilyClassification,
		cliVersionRange: OpenCodeCliVersionRange,
		sessionCapabilities: OpenCodeCapabilitySnapshot.SessionCapabilities,
		certifiedRows: [OpenCodeCertifiedEvidenceRow]
	) {
		self.id = id
		self.classification = classification
		self.cliVersionRange = cliVersionRange
		self.sessionCapabilities = sessionCapabilities
		self.certifiedRows = certifiedRows
	}
}

/// Exactly one axis per known-bad rule so a rule can never silently broaden.
public enum OpenCodeKnownBadMatch: Hashable, Sendable {
	case sha256(OpenCodeSHA256)
	case contractKey(OpenCodeContractKey)
	case cliVersionRange(OpenCodeCliVersionRange)
}

public struct OpenCodeKnownBadRule: Hashable, Sendable {
	public let match: OpenCodeKnownBadMatch
	public let reason: String

	public init(match: OpenCodeKnownBadMatch, reason: String) {
		self.match = match
		self.reason = reason
	}
}

public struct OpenCodeCompatibilityManifest: Hashable, Sendable {
	public static let expectedSchemaVersion = 1

	public let schemaVersion: Int
	public let manifestVersion: String
	public let families: [OpenCodeManifestFamily]
	public let knownBadRules: [OpenCodeKnownBadRule]

	public init(
		schemaVersion: Int,
		manifestVersion: String,
		families: [OpenCodeManifestFamily],
		knownBadRules: [OpenCodeKnownBadRule]
	) {
		self.schemaVersion = schemaVersion
		self.manifestVersion = manifestVersion
		self.families = families
		self.knownBadRules = knownBadRules
	}

	/// Conservative fallback used when no manifest resource can be loaded: nothing is
	/// certified and nothing is known-bad; admission falls back to behavioral gates.
	public static let empty = OpenCodeCompatibilityManifest(
		schemaVersion: expectedSchemaVersion,
		manifestVersion: "empty",
		families: [],
		knownBadRules: []
	)
}

public enum OpenCodeManifestDecodingError: Error, Equatable, CustomStringConvertible {
	case notAnObject
	case missingKey(String)
	case wrongType(String)
	case unexpectedProperty(String)
	case unexpectedSchemaVersion(Int)
	case invalidHash(String)
	case invalidEnum(String)
	case invalidVersion(String)
	case invertedVersionRange(String)
	case emptyString(String)
	case duplicateCertifiedIdentity(String)
	case knownBadMatchAxisCount(Int)

	public var description: String {
		switch self {
		case .notAnObject: return "manifest root is not a JSON object"
		case .missingKey(let key): return "missing key: \(key)"
		case .wrongType(let key): return "wrong type for key: \(key)"
		case .unexpectedProperty(let key): return "unexpected property: \(key)"
		case .unexpectedSchemaVersion(let version): return "unexpected schemaVersion: \(version)"
		case .invalidHash(let value): return "invalid SHA-256: \(value)"
		case .invalidEnum(let value): return "invalid enum member: \(value)"
		case .invalidVersion(let value): return "invalid version: \(value)"
		case .invertedVersionRange(let family): return "inverted version range in family: \(family)"
		case .emptyString(let key): return "empty string for key: \(key)"
		case .duplicateCertifiedIdentity(let key): return "duplicate certified identity: \(key)"
		case .knownBadMatchAxisCount(let count): return "known-bad rule must have exactly one match axis, got \(count)"
		}
	}
}

extension OpenCodeCompatibilityManifest {
	public static func decode(from data: Data) throws -> OpenCodeCompatibilityManifest {
		guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw OpenCodeManifestDecodingError.notAnObject
		}
		try rejectUnexpectedKeys(root, allowed: ["schemaVersion", "manifestVersion", "families", "knownBad"])

		guard let schemaVersion = root["schemaVersion"] as? Int else {
			throw OpenCodeManifestDecodingError.missingKey("schemaVersion")
		}
		guard schemaVersion == expectedSchemaVersion else {
			throw OpenCodeManifestDecodingError.unexpectedSchemaVersion(schemaVersion)
		}
		guard let manifestVersion = root["manifestVersion"] as? String else {
			throw OpenCodeManifestDecodingError.missingKey("manifestVersion")
		}
		guard !manifestVersion.isEmpty else {
			throw OpenCodeManifestDecodingError.emptyString("manifestVersion")
		}
		guard let familiesArray = root["families"] as? [[String: Any]] else {
			throw OpenCodeManifestDecodingError.missingKey("families")
		}
		guard let knownBadArray = root["knownBad"] as? [[String: Any]] else {
			throw OpenCodeManifestDecodingError.missingKey("knownBad")
		}

		var families: [OpenCodeManifestFamily] = []
		var seenIdentities = Set<String>()
		for familyObject in familiesArray {
			let family = try decodeFamily(familyObject)
			for row in family.certifiedRows {
				let identityKey = "\(row.sha256.value):\(row.launchProfileKey.digest.value)"
				guard seenIdentities.insert(identityKey).inserted else {
					throw OpenCodeManifestDecodingError.duplicateCertifiedIdentity(identityKey)
				}
			}
			families.append(family)
		}

		let knownBadRules = try knownBadArray.map(decodeKnownBadRule)

		return OpenCodeCompatibilityManifest(
			schemaVersion: schemaVersion,
			manifestVersion: manifestVersion,
			families: families,
			knownBadRules: knownBadRules
		)
	}

	private static func decodeFamily(_ object: [String: Any]) throws -> OpenCodeManifestFamily {
		try rejectUnexpectedKeys(object, allowed: [
			"id", "classification", "minCliVersion", "maxCliVersion", "sessionCapabilities", "certifiedRows"
		])
		guard let id = object["id"] as? String, !id.isEmpty else {
			throw OpenCodeManifestDecodingError.missingKey("families[].id")
		}
		guard let classificationRaw = object["classification"] as? String else {
			throw OpenCodeManifestDecodingError.missingKey("families[].classification")
		}
		guard let classification = OpenCodeFamilyClassification(rawValue: classificationRaw) else {
			throw OpenCodeManifestDecodingError.invalidEnum(classificationRaw)
		}
		guard let minRaw = object["minCliVersion"] as? String, let minVersion = OpenCodeCliVersion(string: minRaw) else {
			throw OpenCodeManifestDecodingError.invalidVersion((object["minCliVersion"] as? String) ?? "missing")
		}
		guard let maxRaw = object["maxCliVersion"] as? String, let maxVersion = OpenCodeCliVersion(string: maxRaw) else {
			throw OpenCodeManifestDecodingError.invalidVersion((object["maxCliVersion"] as? String) ?? "missing")
		}
		guard let range = OpenCodeCliVersionRange(lowerBound: minVersion, upperBound: maxVersion) else {
			throw OpenCodeManifestDecodingError.invertedVersionRange(id)
		}
		guard let capabilitiesObject = object["sessionCapabilities"] as? [String: Any] else {
			throw OpenCodeManifestDecodingError.missingKey("families[].sessionCapabilities")
		}
		try rejectUnexpectedKeys(capabilitiesObject, allowed: ["loadSession", "listSessions", "resumeSession", "closeSession"])
		func flag(_ key: String) throws -> Bool {
			guard let value = capabilitiesObject[key] as? Bool else {
				throw OpenCodeManifestDecodingError.wrongType("sessionCapabilities.\(key)")
			}
			return value
		}
		let capabilities = OpenCodeCapabilitySnapshot.SessionCapabilities(
			loadSession: try flag("loadSession"),
			listSessions: try flag("listSessions"),
			resumeSession: try flag("resumeSession"),
			closeSession: try flag("closeSession"),
			unstableForkSession: false
		)
		guard let rowsArray = object["certifiedRows"] as? [[String: Any]] else {
			throw OpenCodeManifestDecodingError.missingKey("families[].certifiedRows")
		}
		let rows = try rowsArray.map(decodeCertifiedRow)
		return OpenCodeManifestFamily(
			id: id,
			classification: classification,
			cliVersionRange: range,
			sessionCapabilities: capabilities,
			certifiedRows: rows
		)
	}

	private static func decodeCertifiedRow(_ object: [String: Any]) throws -> OpenCodeCertifiedEvidenceRow {
		try rejectUnexpectedKeys(object, allowed: [
			"sha256", "cliVersion", "architecture", "launchProfileKey", "contractKey",
			"acceptanceID", "provenance", "limitations"
		])
		guard let shaRaw = object["sha256"] as? String, let sha = OpenCodeSHA256(shaRaw) else {
			throw OpenCodeManifestDecodingError.invalidHash((object["sha256"] as? String) ?? "missing")
		}
		guard let versionRaw = object["cliVersion"] as? String, let version = OpenCodeCliVersion(string: versionRaw) else {
			throw OpenCodeManifestDecodingError.invalidVersion((object["cliVersion"] as? String) ?? "missing")
		}
		guard let architectureRaw = object["architecture"] as? String,
			let architecture = OpenCodeExecutableArchitecture(rawValue: architectureRaw) else {
			throw OpenCodeManifestDecodingError.invalidEnum((object["architecture"] as? String) ?? "missing")
		}
		guard let launchRaw = object["launchProfileKey"] as? String, let launchDigest = OpenCodeSHA256(launchRaw) else {
			throw OpenCodeManifestDecodingError.invalidHash((object["launchProfileKey"] as? String) ?? "missing")
		}
		guard let contractRaw = object["contractKey"] as? String, let contractDigest = OpenCodeSHA256(contractRaw) else {
			throw OpenCodeManifestDecodingError.invalidHash((object["contractKey"] as? String) ?? "missing")
		}
		guard let acceptanceID = object["acceptanceID"] as? String, !acceptanceID.isEmpty else {
			throw OpenCodeManifestDecodingError.missingKey("certifiedRows[].acceptanceID")
		}
		guard let provenanceRaw = object["provenance"] as? String,
			let provenance = OpenCodeEvidenceProvenance(rawValue: provenanceRaw) else {
			throw OpenCodeManifestDecodingError.invalidEnum((object["provenance"] as? String) ?? "missing")
		}
		let limitations = (object["limitations"] as? [String]) ?? []
		return OpenCodeCertifiedEvidenceRow(
			sha256: sha,
			cliVersion: version,
			architecture: architecture,
			launchProfileKey: OpenCodeLaunchProfileKey(digest: launchDigest),
			contractKey: OpenCodeContractKey(digest: contractDigest),
			acceptanceID: acceptanceID,
			provenance: provenance,
			limitations: limitations
		)
	}

	private static func decodeKnownBadRule(_ object: [String: Any]) throws -> OpenCodeKnownBadRule {
		try rejectUnexpectedKeys(object, allowed: ["sha256", "contractKey", "minCliVersion", "maxCliVersion", "reason"])
		guard let reason = object["reason"] as? String, !reason.isEmpty else {
			throw OpenCodeManifestDecodingError.missingKey("knownBad[].reason")
		}
		var axes = 0
		var match: OpenCodeKnownBadMatch?
		if let shaRaw = object["sha256"] as? String {
			guard let sha = OpenCodeSHA256(shaRaw) else {
				throw OpenCodeManifestDecodingError.invalidHash(shaRaw)
			}
			match = .sha256(sha)
			axes += 1
		}
		if let contractRaw = object["contractKey"] as? String {
			guard let digest = OpenCodeSHA256(contractRaw) else {
				throw OpenCodeManifestDecodingError.invalidHash(contractRaw)
			}
			match = .contractKey(OpenCodeContractKey(digest: digest))
			axes += 1
		}
		if object["minCliVersion"] != nil || object["maxCliVersion"] != nil {
			guard let minRaw = object["minCliVersion"] as? String,
				let maxRaw = object["maxCliVersion"] as? String,
				let minVersion = OpenCodeCliVersion(string: minRaw),
				let maxVersion = OpenCodeCliVersion(string: maxRaw),
				let range = OpenCodeCliVersionRange(lowerBound: minVersion, upperBound: maxVersion)
			else {
				throw OpenCodeManifestDecodingError.invalidVersion("knownBad[].cliVersionRange")
			}
			match = .cliVersionRange(range)
			axes += 1
		}
		guard axes == 1, let resolvedMatch = match else {
			throw OpenCodeManifestDecodingError.knownBadMatchAxisCount(axes)
		}
		return OpenCodeKnownBadRule(match: resolvedMatch, reason: reason)
	}

	private static func rejectUnexpectedKeys(_ object: [String: Any], allowed: Set<String>) throws {
		for key in object.keys where !allowed.contains(key) {
			throw OpenCodeManifestDecodingError.unexpectedProperty(key)
		}
	}
}

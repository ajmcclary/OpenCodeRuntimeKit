import Foundation

// Typed compatibility keys with domain-separated canonical encodings.
//
// Two distinct key types exist so axes can never be swapped at a call site:
// - `OpenCodeLaunchProfileKey`: derived only from behavior-changing launch inputs
//   (transport, listener security, tool profile, overlay shape, cwd class, pure mode,
//   effective config digest).
// - `OpenCodeContractKey`: derived only from protocol/contract evidence (ACP protocol
//   version, agent identity family, capability snapshot digest, used-surface lock hash).

/// Bounded launch transport classes RepoPrompt can produce.
public enum OpenCodeTransportClass: String, Hashable, Sendable, CaseIterable {
	case acpStdio
}

/// Whether the internal HTTP listener started by `opencode acp` is constrained to the
/// authenticated numeric-loopback profile.
public enum OpenCodeListenerSecurityClass: String, Hashable, Sendable, CaseIterable {
	case authenticatedLoopback
	case unconstrained
}

/// Managed tool-profile classes derivable from shipping factories.
public enum OpenCodeToolProfileClass: String, Hashable, Sendable, CaseIterable {
	case agentMode
	case agentModeFullAccess
	case headless
	case noTools
}

/// Shape of the process-ephemeral config overlay.
public enum OpenCodeOverlayClass: String, Hashable, Sendable, CaseIterable {
	case managedWithActiveMCP
	case managedWithDisabledMCP
	case none
}

/// Working-directory classes (never raw paths — paths are user data).
public enum OpenCodeWorkingDirectoryClass: String, Hashable, Sendable, CaseIterable {
	case workspaceRoot
	case temporaryDirectory
}

/// Domain-separated digest wrapper for the serialized effective overlay/config content.
/// Only a digest may enter a key input; raw config never does.
public struct OpenCodeConfigDigest: Hashable, Sendable {
	public let sha256: OpenCodeSHA256

	public init(sha256: OpenCodeSHA256) {
		self.sha256 = sha256
	}
}

/// Deterministic canonical byte encoder. Fields are encoded as
/// `<domain>\n<field>=<value>\n...` in declaration order with a fixed domain tag, so two
/// different key types can never produce colliding canonical bytes for the same field set.
enum OpenCodeCanonicalEncoder {
	/// Length-prefixed framing (sixth-round audit). Joining names and values with `=`
	/// and `\n` is ambiguous whenever a value can contain those bytes — and one of these
	/// values, the advertised `agentName`, comes straight off the wire from the runtime
	/// being keyed. A value carrying a newline could otherwise forge a field boundary
	/// and make two different launch profiles share a key. Each field is now framed by
	/// its big-endian 64-bit byte length, so content can never impersonate structure.
	static func encode(domain: String, fields: [(String, String)]) -> Data {
		var out = [UInt8]()
		func append(_ string: String) {
			let bytes = Array(string.utf8)
			out.append(contentsOf: withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { Array($0) })
			out.append(contentsOf: bytes)
		}
		append("opencode-key-domain")
		append(domain)
		for (name, value) in fields {
			append(name)
			append(value)
		}
		return Data(out)
	}
}

/// Complete behavior-changing launch inputs for one OpenCode ACP launch/probe.
public struct OpenCodeLaunchProfileKeyInput: Hashable, Sendable {
	public let transport: OpenCodeTransportClass
	public let listenerSecurity: OpenCodeListenerSecurityClass
	public let toolProfile: OpenCodeToolProfileClass
	public let overlay: OpenCodeOverlayClass
	public let workingDirectoryClass: OpenCodeWorkingDirectoryClass
	public let pureMode: Bool
	public let overlayConfigDigest: OpenCodeConfigDigest?

	public init(
		transport: OpenCodeTransportClass,
		listenerSecurity: OpenCodeListenerSecurityClass,
		toolProfile: OpenCodeToolProfileClass,
		overlay: OpenCodeOverlayClass,
		workingDirectoryClass: OpenCodeWorkingDirectoryClass,
		pureMode: Bool,
		overlayConfigDigest: OpenCodeConfigDigest?
	) {
		self.transport = transport
		self.listenerSecurity = listenerSecurity
		self.toolProfile = toolProfile
		self.overlay = overlay
		self.workingDirectoryClass = workingDirectoryClass
		self.pureMode = pureMode
		self.overlayConfigDigest = overlayConfigDigest
	}

	public var canonicalBytes: Data {
		OpenCodeCanonicalEncoder.encode(domain: "launch-profile.v1", fields: [
			("transport", transport.rawValue),
			("listenerSecurity", listenerSecurity.rawValue),
			("toolProfile", toolProfile.rawValue),
			("overlay", overlay.rawValue),
			("workingDirectoryClass", workingDirectoryClass.rawValue),
			("pureMode", pureMode ? "true" : "false"),
			("overlayConfigDigest", overlayConfigDigest?.sha256.value ?? "absent")
		])
	}
}

/// Contract-evidence inputs: what the runtime advertises plus the used-surface lock.
public struct OpenCodeContractKeyInput: Hashable, Sendable {
	public let acpProtocolVersion: Int
	public let agentName: String
	public let capabilitySnapshotDigest: OpenCodeSHA256
	public let usedSurfaceLockHash: OpenCodeSHA256?

	public init(
		acpProtocolVersion: Int,
		agentName: String,
		capabilitySnapshotDigest: OpenCodeSHA256,
		usedSurfaceLockHash: OpenCodeSHA256?
	) {
		self.acpProtocolVersion = acpProtocolVersion
		self.agentName = agentName
		self.capabilitySnapshotDigest = capabilitySnapshotDigest
		self.usedSurfaceLockHash = usedSurfaceLockHash
	}

	public var canonicalBytes: Data {
		OpenCodeCanonicalEncoder.encode(domain: "contract.v1", fields: [
			("acpProtocolVersion", String(acpProtocolVersion)),
			("agentName", agentName),
			("capabilitySnapshotDigest", capabilitySnapshotDigest.value),
			("usedSurfaceLockHash", usedSurfaceLockHash?.value ?? "absent")
		])
	}
}

/// Typed launch-profile key. Distinct from `OpenCodeContractKey` on purpose.
public struct OpenCodeLaunchProfileKey: Hashable, Sendable, CustomStringConvertible {
	public let digest: OpenCodeSHA256

	public init(input: OpenCodeLaunchProfileKeyInput) {
		self.digest = OpenCodeSHA256Digest.digest(of: input.canonicalBytes)
	}

	public init(digest: OpenCodeSHA256) {
		self.digest = digest
	}

	public var description: String { "launch-profile:\(digest.value)" }
}

/// Typed contract key.
public struct OpenCodeContractKey: Hashable, Sendable, CustomStringConvertible {
	public let digest: OpenCodeSHA256

	public init(input: OpenCodeContractKeyInput) {
		self.digest = OpenCodeSHA256Digest.digest(of: input.canonicalBytes)
	}

	public init(digest: OpenCodeSHA256) {
		self.digest = digest
	}

	public var description: String { "contract:\(digest.value)" }
}

/// Minimal dependency-free SHA-256 (the core target cannot import CryptoKit's
/// availability surface indirectly through app helpers; this keeps digesting pure and
/// deterministic). Implementation follows FIPS 180-4.
public enum OpenCodeSHA256Digest {
	public static func digest(of data: Data) -> OpenCodeSHA256 {
		var hash: [UInt32] = [
			0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
			0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19
		]
		let k: [UInt32] = [
			0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
			0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
			0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
			0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
			0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
			0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
			0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
			0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
		]

		var message = [UInt8](data)
		let bitLength = UInt64(message.count) * 8
		message.append(0x80)
		while message.count % 64 != 56 {
			message.append(0)
		}
		for shift in stride(from: 56, through: 0, by: -8) {
			message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
		}

		for chunkStart in stride(from: 0, to: message.count, by: 64) {
			var w = [UInt32](repeating: 0, count: 64)
			for i in 0..<16 {
				let base = chunkStart + i * 4
				w[i] = (UInt32(message[base]) << 24)
					| (UInt32(message[base + 1]) << 16)
					| (UInt32(message[base + 2]) << 8)
					| UInt32(message[base + 3])
			}
			for i in 16..<64 {
				let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
				let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
				w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
			}

			var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
			var e = hash[4], f = hash[5], g = hash[6], h = hash[7]

			for i in 0..<64 {
				let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
				let ch = (e & f) ^ (~e & g)
				let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
				let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
				let maj = (a & b) ^ (a & c) ^ (b & c)
				let temp2 = s0 &+ maj
				h = g; g = f; f = e
				e = d &+ temp1
				d = c; c = b; b = a
				a = temp1 &+ temp2
			}

			hash[0] &+= a; hash[1] &+= b; hash[2] &+= c; hash[3] &+= d
			hash[4] &+= e; hash[5] &+= f; hash[6] &+= g; hash[7] &+= h
		}

		let hex = hash.map { String(format: "%08x", $0) }.joined()
		// The 64-char lowercase hex output always satisfies OpenCodeSHA256's validation.
		return OpenCodeSHA256(hex)!
	}

	public static func digest(ofUTF8 string: String) -> OpenCodeSHA256 {
		digest(of: Data(string.utf8))
	}

	private static func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
		(value >> amount) | (value << (32 - amount))
	}
}

import Foundation

/// Resumable SHA-256 state (FIPS 180-4) that can be persisted mid-stream.
///
/// Why this exists (fifth round, finding 3): replay reconciliation needs CONTENT proof
/// for a message whose text arrived as an arbitrary sequence of chunks, in a process
/// that may die between chunks. That rules out three otherwise obvious options:
///
///   * FNV-1a-64 (what shipped before) is deterministic and chunk-additive but is a
///     non-cryptographic 64-bit hash — it is not content proof, and an attacker or an
///     unlucky provider stream can produce a colliding prefix.
///   * `CryptoKit.SHA256` is cryptographic and incremental but its in-progress state is
///     not serializable, and the core target must not import CryptoKit at all (R1).
///   * Chaining whole-digest values (`SHA256(previous || chunk)`) is serializable but
///     chunking-DEPENDENT, which is exactly the defect being fixed.
///
/// So the compression state itself (the eight chaining words, the sub-block tail buffer,
/// and the total byte count) is the persisted unit. Feeding "e" then U+0301 and feeding
/// "é" (as the same UTF-8 bytes) reach byte-identical state, and `finalizedHex()`
/// equals the one-shot digest of the concatenated bytes.
public struct OpenCodeIncrementalSHA256: Hashable, Sendable, Codable {
	private static let initialState: [UInt32] = [
		0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
		0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19
	]

	private static let k: [UInt32] = [
		0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
		0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
		0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
		0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
		0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
		0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
		0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
		0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
	]

	/// Chaining value after every complete 64-byte block absorbed so far.
	private var state: [UInt32]
	/// Bytes of the trailing partial block (always fewer than 64).
	private var tail: [UInt8]
	/// Total bytes absorbed, including `tail`.
	public private(set) var byteCount: UInt64

	public init() {
		self.state = Self.initialState
		self.tail = []
		self.byteCount = 0
	}

	private init(validatedState: [UInt32], tail: [UInt8], byteCount: UInt64) {
		self.state = validatedState
		self.tail = tail
		self.byteCount = byteCount
	}

	// MARK: - Fail-closed decoding

	private enum CodingKeys: String, CodingKey {
		case state
		case tail
		case byteCount
	}

	/// Persisted state is UNTRUSTED input (sixth round, finding 1). The synthesized
	/// `Codable` conformance accepted any array shape, so a recovery file carrying a
	/// short `state`, a `tail` of 64 bytes or more, or a `byteCount` inconsistent with
	/// the tail would decode cleanly and then trap inside `finalizedHex()` — either
	/// indexing past the chaining words or hitting the 64-byte block precondition.
	/// A malformed record must make recovery REFUSE, never crash the app, so every
	/// structural invariant the algorithm assumes is checked here:
	///
	///   * exactly eight chaining words;
	///   * a tail strictly shorter than one block;
	///   * `byteCount >= tail.count`, and `byteCount % 64 == tail.count` — the tail is
	///     by construction the remainder after every whole block was absorbed;
	///   * a bit length that cannot overflow `UInt64` during finalization.
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let state = try container.decode([UInt32].self, forKey: .state)
		let tail = try container.decode([UInt8].self, forKey: .tail)
		let byteCount = try container.decode(UInt64.self, forKey: .byteCount)
		guard state.count == 8 else {
			throw DecodingError.dataCorruptedError(
				forKey: .state, in: container,
				debugDescription: "SHA-256 chaining state must be exactly 8 words, got \(state.count)"
			)
		}
		guard tail.count < 64 else {
			throw DecodingError.dataCorruptedError(
				forKey: .tail, in: container,
				debugDescription: "SHA-256 tail must be shorter than one 64-byte block, got \(tail.count)"
			)
		}
		guard byteCount >= UInt64(tail.count), byteCount % 64 == UInt64(tail.count) else {
			throw DecodingError.dataCorruptedError(
				forKey: .byteCount, in: container,
				debugDescription: "SHA-256 byte count \(byteCount) is inconsistent with a \(tail.count)-byte tail"
			)
		}
		guard byteCount <= UInt64.max / 8 else {
			throw DecodingError.dataCorruptedError(
				forKey: .byteCount, in: container,
				debugDescription: "SHA-256 byte count \(byteCount) overflows the bit-length field"
			)
		}
		self.init(validatedState: state, tail: tail, byteCount: byteCount)
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(state, forKey: .state)
		try container.encode(tail, forKey: .tail)
		try container.encode(byteCount, forKey: .byteCount)
	}

	/// True for a state that has absorbed nothing — distinguishable from "absorbed an
	/// empty chunk", which is also nothing, and from "no evidence recorded at all",
	/// which the caller represents with a nil state.
	public var isEmpty: Bool { byteCount == 0 }

	/// True once the state has absorbed as many bytes as the 64-bit bit-length field can
	/// describe. A saturated state can no longer absorb faithfully, so callers must
	/// treat it as unusable evidence rather than continuing (seventh round, finding 2).
	public var isSaturated: Bool { byteCount >= UInt64.max / 8 }

	/// Absorbs bytes. Stops at saturation instead of wrapping the bit-length field —
	/// `&+=` would silently produce a digest describing a different message length.
	/// Callers detect the condition through `isSaturated`.
	public mutating func update<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
		for byte in bytes {
			guard !isSaturated else { return }
			tail.append(byte)
			byteCount += 1
			if tail.count == 64 {
				Self.compress(block: tail, into: &state)
				tail.removeAll(keepingCapacity: true)
			}
		}
	}

	public mutating func update(utf8 string: String) {
		update(string.utf8)
	}

	/// The digest of everything absorbed so far, as lowercase hex. Non-mutating: the
	/// state can keep absorbing afterwards (padding is applied to a copy).
	public func finalizedHex() -> String {
		var finalState = state
		var block = tail
		let bitLength = byteCount &* 8
		block.append(0x80)
		if block.count > 56 {
			// The 0x80 byte pushed the tail past the 8-byte length field: flush a full
			// block first, then emit a second, all-padding block carrying the length.
			while block.count < 64 { block.append(0) }
			Self.compress(block: block, into: &finalState)
			block.removeAll(keepingCapacity: true)
		}
		while block.count < 56 { block.append(0) }
		for shift in stride(from: 56, through: 0, by: -8) {
			block.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
		}
		Self.compress(block: block, into: &finalState)
		return finalState.map { String(format: "%08x", $0) }.joined()
	}

	private static func compress(block: [UInt8], into hash: inout [UInt32]) {
		precondition(block.count == 64, "SHA-256 compression requires a full 64-byte block")
		var w = [UInt32](repeating: 0, count: 64)
		for i in 0..<16 {
			let base = i * 4
			w[i] = (UInt32(block[base]) << 24)
				| (UInt32(block[base + 1]) << 16)
				| (UInt32(block[base + 2]) << 8)
				| UInt32(block[base + 3])
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

	private static func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
		(value >> amount) | (value << (32 - amount))
	}
}

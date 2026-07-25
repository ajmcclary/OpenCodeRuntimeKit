import Foundation

/// Stateful fragmented tool-input assembly keyed by provider session ID + tool call ID
/// (NOW-2). OpenCode can emit an initial `tool_call` followed by incremental
/// `tool_call_update` frames; this assembler merges them deterministically:
///
/// - structured fields merge last-writer-wins per key;
/// - protocol-defined text fragments append in arrival order;
/// - conflicting whole-value snapshots are retained (latest wins, prior retained);
/// - finalize happens exactly once on terminal status;
/// - duplicate terminal updates and post-terminal (late) updates are counted, not merged;
/// - memory is bounded: least-recently-touched open calls are expired beyond the cap,
///   and `expireAll` handles turn end/cancel/process exit.
public struct OpenCodePartialToolInputAssembler: Sendable {
	public struct Key: Hashable, Sendable {
		public let sessionID: String
		public let toolCallID: String

		public init(sessionID: String, toolCallID: String) {
			self.sessionID = sessionID
			self.toolCallID = toolCallID
		}
	}

	public enum TerminalState: String, Hashable, Sendable {
		case completed
		case failed
		case cancelled
		case expired
	}

	public struct AssembledCall: Hashable, Sendable {
		public let key: Key
		public let toolName: String?
		/// Deterministically merged structured input, JSON-serialized with sorted keys.
		public let mergedInputJSON: String?
		public let appendedText: String
		public let conflictingSnapshotCount: Int
		public let updateCount: Int
		public let terminalState: TerminalState
		/// True when the call expired without a protocol terminal state — the caller must
		/// surface an explicit incomplete-input state, never a fabricated final input.
		public var isIncomplete: Bool { terminalState == .expired }
	}

	public struct Metrics: Hashable, Sendable {
		public var openCalls: Int = 0
		public var finalized: Int = 0
		public var duplicateTerminals: Int = 0
		public var lateUpdates: Int = 0
		public var expired: Int = 0
		public var conflicts: Int = 0

		public init() {}
	}

	/// One merged input field, stored in a genuinely `Sendable` form.
	///
	/// The assembler is a public `Sendable` value type, so it cannot STORE the
	/// `[String: Any]` it ingests — `Any` carries no concurrency guarantee, and
	/// the values arriving from the wire are Foundation reference types
	/// (`NSString`/`NSNumber`/`NSArray`/`NSDictionary`). Each field is therefore
	/// normalized at ingest into its canonical JSON encoding, which is a `Data`
	/// value: the assembler becomes genuinely sendable rather than
	/// asserted-sendable, and no `@unchecked` conformance is needed.
	///
	/// The encoding is exactly the byte sequence the conflict comparison already
	/// computed (`["v": value]` serialized with `.sortedKeys`), so
	/// conflict detection is unchanged; the final document is rebuilt by
	/// decoding these values and handing the object back to `JSONSerialization`,
	/// so key ordering and escaping stay owned by Foundation.
	enum Field: Sendable {
		/// `JSONSerialization` output for `["v": value]` with `.sortedKeys`.
		case json(Data)
		/// The value is not JSON-representable (a non-JSON type, or a non-finite
		/// number). Deliberately NOT `Equatable`: an unrepresentable value is
		/// never equivalent to anything, including another unrepresentable value
		/// — which is what the previous `jsonEquivalent` did, since it returned
		/// `false` whenever either side failed to serialize.
		case unrepresentable
	}

	private struct OpenCall: Sendable {
		var toolName: String?
		var mergedInput: [String: Field] = [:]
		var appendedText = ""
		var conflictingSnapshotCount = 0
		var updateCount = 0
		var lastTouchOrdinal: UInt64 = 0
	}

	public private(set) var metrics = Metrics()
	private var openCalls: [Key: OpenCall] = [:]
	private var finalizedKeys: Set<Key> = []
	private var touchCounter: UInt64 = 0
	private let maxOpenCalls: Int
	/// Calls expired by the capacity bound, pending pickup via `drainEvictedCalls()`.
	/// Eviction is a real incomplete-input disposition, not silent bookkeeping: the
	/// caller must surface each evicted call exactly once.
	private var pendingEvictedCalls: [AssembledCall] = []

	public init(maxOpenCalls: Int = 64) {
		self.maxOpenCalls = max(1, maxOpenCalls)
	}

	/// Classified outcome of one ingested payload. Production normalization uses this
	/// to suppress duplicate-terminal and late-after-terminal frames (counted, never
	/// re-emitted downstream); the optional-returning `ingest` keeps the simpler API
	/// for fixtures.
	public enum IngestOutcome {
		case accumulated
		case terminal(AssembledCall)
		case duplicateTerminal
		case lateUpdate
	}

	/// Feeds one tool_call / tool_call_update payload. Returns the assembled call when the
	/// update carries a terminal status, nil otherwise.
	public mutating func ingest(
		key: Key,
		toolName: String?,
		rawInput: [String: Any]?,
		textFragment: String?,
		status: String?
	) -> AssembledCall? {
		if case .terminal(let assembled) = ingestClassified(
			key: key,
			toolName: toolName,
			rawInput: rawInput,
			textFragment: textFragment,
			status: status
		) {
			return assembled
		}
		return nil
	}

	/// Feeds one payload and reports the classified outcome.
	public mutating func ingestClassified(
		key: Key,
		toolName: String?,
		rawInput: [String: Any]?,
		textFragment: String?,
		status: String?
	) -> IngestOutcome {
		if finalizedKeys.contains(key) {
			let normalizedStatus = status?.lowercased()
			if normalizedStatus == "completed" || normalizedStatus == "failed"
				|| normalizedStatus == "error" || normalizedStatus == "cancelled" || normalizedStatus == "canceled" {
				metrics.duplicateTerminals += 1
				return .duplicateTerminal
			}
			metrics.lateUpdates += 1
			return .lateUpdate
		}

		touchCounter += 1
		var call = openCalls[key] ?? OpenCall()
		call.updateCount += 1
		call.lastTouchOrdinal = touchCounter
		if let toolName, !toolName.isEmpty {
			call.toolName = call.toolName ?? toolName
		}
		if let rawInput {
			for (field, value) in rawInput {
				let encoded = Self.encodeField(value)
				if let existing = call.mergedInput[field],
					!Self.fieldsEquivalent(existing, encoded) {
					call.conflictingSnapshotCount += 1
					metrics.conflicts += 1
				}
				call.mergedInput[field] = encoded
			}
		}
		if let textFragment, !textFragment.isEmpty {
			call.appendedText += textFragment
		}
		openCalls[key] = call
		metrics.openCalls = openCalls.count

		let terminal: TerminalState?
		switch status?.lowercased() {
		case "completed": terminal = .completed
		case "failed", "error": terminal = .failed
		case "cancelled", "canceled": terminal = .cancelled
		default: terminal = nil
		}

		if let terminal {
			if let assembled = finalize(key: key, state: terminal) {
				return .terminal(assembled)
			}
			return .accumulated
		}

		enforceCapacityBound()
		return .accumulated
	}

	/// Finalizes one open call. Idempotent: a second finalize returns nil.
	public mutating func finalize(key: Key, state: TerminalState) -> AssembledCall? {
		guard let call = openCalls.removeValue(forKey: key) else {
			if finalizedKeys.contains(key) {
				metrics.duplicateTerminals += 1
			}
			return nil
		}
		finalizedKeys.insert(key)
		metrics.finalized += 1
		metrics.openCalls = openCalls.count
		if state == .expired {
			metrics.expired += 1
		}
		return AssembledCall(
			key: key,
			toolName: call.toolName,
			mergedInputJSON: Self.serializeSorted(call.mergedInput),
			appendedText: call.appendedText,
			conflictingSnapshotCount: call.conflictingSnapshotCount,
			updateCount: call.updateCount,
			terminalState: state
		)
	}

	/// Expires every open call (turn end, cancellation, process exit). Each expired call
	/// is returned with an explicit incomplete-input state.
	public mutating func expireAll() -> [AssembledCall] {
		let keys = openCalls.keys.sorted { lhs, rhs in
			(lhs.sessionID, lhs.toolCallID) < (rhs.sessionID, rhs.toolCallID)
		}
		return keys.compactMap { finalize(key: $0, state: .expired) }
	}

	/// Expires open calls for one session only.
	public mutating func expireSession(_ sessionID: String) -> [AssembledCall] {
		let keys = openCalls.keys
			.filter { $0.sessionID == sessionID }
			.sorted { $0.toolCallID < $1.toolCallID }
		return keys.compactMap { finalize(key: $0, state: .expired) }
	}

	private mutating func enforceCapacityBound() {
		while openCalls.count > maxOpenCalls {
			guard let oldest = openCalls.min(by: { $0.value.lastTouchOrdinal < $1.value.lastTouchOrdinal })?.key else {
				return
			}
			if let evicted = finalize(key: oldest, state: .expired) {
				pendingEvictedCalls.append(evicted)
			}
		}
	}

	/// Returns (and clears) the calls the capacity bound expired since the last drain.
	/// Each evicted call carries the explicit incomplete-input state exactly once.
	public mutating func drainEvictedCalls() -> [AssembledCall] {
		let evicted = pendingEvictedCalls
		pendingEvictedCalls = []
		return evicted
	}

	/// Normalizes one ingested value into its canonical, sendable encoding.
	///
	/// `isValidJSONObject` applies the same per-value rules to `["v": value]`
	/// that it applies to the whole merged object, so a value that cannot be
	/// encoded here is exactly a value that would have made the whole-object
	/// serialization fail.
	static func encodeField(_ value: Any) -> Field {
		let wrapper: [String: Any] = ["v": value]
		guard JSONSerialization.isValidJSONObject(wrapper),
			let data = try? JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys])
		else { return .unrepresentable }
		return .json(data)
	}

	/// Conflict comparison. An unrepresentable value is never equivalent — not
	/// even to another unrepresentable value.
	static func fieldsEquivalent(_ lhs: Field, _ rhs: Field) -> Bool {
		guard case .json(let lhsData) = lhs, case .json(let rhsData) = rhs else { return false }
		return lhsData == rhsData
	}

	/// Decodes a stored field back to a JSON value for document assembly.
	///
	/// KNOWN DIVERGENCE — negative zero. Serializing at ingest and decoding here
	/// is value-preserving for every shape reachable from a decoded wire payload
	/// except `-0.0`: it emits as `-0`, which carries no `.` or exponent and so
	/// re-parses as an *integer* zero, re-emitting as `0`. Before this type
	/// stored per-field `Data`, the original value survived to a single
	/// end-of-life serialization and `-0` was preserved.
	///
	/// Splicing the stored canonical bytes would preserve it, but that would
	/// require reimplementing `JSONSerialization`'s `.sortedKeys` collation,
	/// which is not byte order — a far larger wire risk than the one it fixes.
	/// Pinned by `testNegativeZeroIsTheOneKnownRoundTripDivergence()`.
	static func decodeField(_ field: Field) -> Any? {
		guard case .json(let data) = field,
			let wrapper = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
		else { return nil }
		return wrapper["v"]
	}

	/// Rebuilds the merged document. A single unrepresentable field yields nil,
	/// matching the whole-object `isValidJSONObject` check below.
	static func serializeSorted(_ fields: [String: Field]) -> String? {
		guard !fields.isEmpty else { return nil }
		var object: [String: Any] = [:]
		object.reserveCapacity(fields.count)
		for (name, field) in fields {
			guard let value = decodeField(field) else { return nil }
			object[name] = value
		}
		return serializeSorted(object)
	}

	static func serializeSorted(_ object: [String: Any]) -> String? {
		guard !object.isEmpty,
			JSONSerialization.isValidJSONObject(object),
			let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
		else { return nil }
		return String(data: data, encoding: .utf8)
	}
}

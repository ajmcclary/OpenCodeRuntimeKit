import Foundation

// Process-death recovery vocabulary and the pure recovery planner (NEXT-1).
//
// On transport/process loss RepoPrompt: stops accepting approvals, snapshots pending
// calls, re-resolves and re-admits the runtime, attempts AT MOST ONE capability-gated
// resume/load, deduplicates replay against the stored frontier, and NEVER silently
// creates a replacement provider session. Anything else is an explicit refusal that the
// UI must present as failure/handoff, visibly distinct from resume.

/// Durable identity persisted for one provider session so recovery can validate that it
/// is reattaching to the SAME session under the SAME conditions.
public struct OpenCodeSessionRecoveryRecord: Hashable, Sendable, Codable {
	public let providerSessionID: String
	/// Canonical (symlink-resolved) workspace root the session was created under.
	public let canonicalRootPath: String
	/// Byte identity of the runtime that owned the session.
	public let runtimeSHA256Hex: String?
	public let cliVersion: String?
	/// Raw model selection (provider/model/variant kept opaque).
	public let modelSelectionRaw: String?
	public let sessionModeID: String?
	public let frontier: OpenCodeTranscriptFrontier
	/// The session capabilities last advertised (post-admission) by the runtime that
	/// owned this session; used by the recovery planner before a replacement runtime's
	/// own advertisement is available.
	public let lastSessionCapabilities: OpenCodeCapabilitySnapshot.SessionCapabilities?

	public init(
		providerSessionID: String,
		canonicalRootPath: String,
		runtimeSHA256Hex: String?,
		cliVersion: String?,
		modelSelectionRaw: String?,
		sessionModeID: String?,
		frontier: OpenCodeTranscriptFrontier,
		lastSessionCapabilities: OpenCodeCapabilitySnapshot.SessionCapabilities? = nil
	) {
		self.providerSessionID = providerSessionID
		self.canonicalRootPath = canonicalRootPath
		self.runtimeSHA256Hex = runtimeSHA256Hex
		self.cliVersion = cliVersion
		self.modelSelectionRaw = modelSelectionRaw
		self.sessionModeID = sessionModeID
		self.frontier = frontier
		self.lastSessionCapabilities = lastSessionCapabilities
	}
}

/// Durable transcript frontier for replay deduplication during `session/load` recovery.
/// Bounded: only the identifiers needed to recognize already-seen provider content.
///
/// Beyond the ID sets, the frontier records HOW MUCH of each message was observed
/// (cumulative rendered text length per message ID) and WHICH tool calls reached a
/// terminal status, so a replay of a partially observed message can suppress exactly
/// the already-rendered prefix while delivering the unseen suffix, and a tool call
/// whose terminal update was never observed can still complete from replay.
public struct OpenCodeTranscriptFrontier: Hashable, Sendable, Codable {
	public static let maxTrackedIdentifiers = 512

	/// Version of the per-message content-evidence encoding (fifth round, findings 1
	/// and 3). Version 2 records:
	///   * coverage in UNICODE SCALARS, which are additive across chunk boundaries —
	///     extended grapheme clusters are not (`"e"` + U+0301 counts 2 as separate
	///     chunks but 1 once combined, so a valid replay with different boundaries was
	///     being refused);
	///   * content proof as a resumable SHA-256 state rather than FNV-1a-64, which is
	///     deterministic but not collision-resistant and so is not content proof.
	/// Version 1 records (character counts + FNV values) are NOT reinterpretable under
	/// these semantics, so decoding one fails closed — see `hasUnsupportedContentEvidence`.
	public static let contentEvidenceVersion = 2

	public private(set) var seenMessageIDs: [String]
	public private(set) var seenToolCallIDs: [String]
	/// Cumulative observed (rendered) text length per message ID, in UNICODE SCALARS.
	/// Absent for message IDs recorded by a pre-coverage frontier; callers must treat
	/// absence as "whole message observed" (the legacy suppress-by-ID semantics).
	public private(set) var observedMessageTextScalarCounts: [String: Int]
	/// Resumable SHA-256 over the cumulative observed UTF-8 text per message ID
	/// (content-integrity evidence: replay dedup must prove the replayed prefix IS the
	/// rendered prefix, not merely the same length). Chunking-independent by
	/// construction — the compression state, not a chained digest, is what persists.
	public private(set) var observedMessageTextDigests: [String: OpenCodeIncrementalSHA256]
	/// Message IDs whose rendered prefix a recovery replay MUST prove it covered
	/// (fifth round, finding 2): the messages that were still streaming when the
	/// frontier was taken. A `session/load` that omits such a message entirely, or
	/// replays it as empty chunks only, produces no progress entry at all — without an
	/// explicit requirement the reconciler saw nothing wrong and reported success.
	/// Completed turns clear the set, so sparse history for finished messages stays
	/// legal.
	public private(set) var requiredReplayCoverageMessageIDs: [String]
	/// True when the record carried content evidence this build cannot interpret
	/// (a version-1 record, or a version from the future). Automatic recovery must
	/// refuse rather than silently reinterpret a foreign checksum as a digest.
	public private(set) var hasUnsupportedContentEvidence: Bool
	/// Tool call IDs whose terminal update was observed before the frontier was taken.
	public private(set) var terminalToolCallIDs: [String]
	/// True once any identifier could not be recorded within the bound. An overflowed
	/// frontier is NOT a faithful representation of the transcript: replay dedup
	/// against it would treat forgotten history as unseen and duplicate it, so
	/// automatic recovery must refuse rather than fail open (fourth round, finding 4).
	public private(set) var didOverflow: Bool
	public let lastEventOrdinal: Int

	public init(
		seenMessageIDs: [String] = [],
		seenToolCallIDs: [String] = [],
		lastEventOrdinal: Int = 0,
		observedMessageTextScalarCounts: [String: Int] = [:],
		terminalToolCallIDs: [String] = [],
		observedMessageTextDigests: [String: OpenCodeIncrementalSHA256] = [:],
		requiredReplayCoverageMessageIDs: [String] = [],
		didOverflow: Bool = false,
		hasUnsupportedContentEvidence: Bool = false
	) {
		let overflowed = didOverflow
			|| seenMessageIDs.count > Self.maxTrackedIdentifiers
			|| seenToolCallIDs.count > Self.maxTrackedIdentifiers
			|| terminalToolCallIDs.count > Self.maxTrackedIdentifiers
		let boundedMessages = Array(seenMessageIDs.prefix(Self.maxTrackedIdentifiers))
		let boundedMessageSet = Set(boundedMessages)
		self.seenMessageIDs = boundedMessages
		self.seenToolCallIDs = Array(seenToolCallIDs.prefix(Self.maxTrackedIdentifiers))
		self.observedMessageTextScalarCounts = observedMessageTextScalarCounts.filter { boundedMessageSet.contains($0.key) }
		self.observedMessageTextDigests = observedMessageTextDigests.filter { boundedMessageSet.contains($0.key) }
		self.requiredReplayCoverageMessageIDs = requiredReplayCoverageMessageIDs.filter { boundedMessageSet.contains($0) }
		self.terminalToolCallIDs = Array(terminalToolCallIDs.prefix(Self.maxTrackedIdentifiers))
		self.didOverflow = overflowed
		self.hasUnsupportedContentEvidence = hasUnsupportedContentEvidence
		self.lastEventOrdinal = lastEventOrdinal
	}

	/// Trusted fast path for `advanced(...)`: inputs are already bounded/consistent,
	/// so no re-filtering happens. The public init's O(n) validation on EVERY advance
	/// made frontier maintenance quadratic and let a process-exit handler interleave
	/// ahead of still-queued transcript updates.
	private init(
		trustedSeenMessageIDs: [String],
		trustedSeenToolCallIDs: [String],
		lastEventOrdinal: Int,
		trustedObservedMessageTextScalarCounts: [String: Int],
		trustedTerminalToolCallIDs: [String],
		trustedObservedMessageTextDigests: [String: OpenCodeIncrementalSHA256],
		trustedRequiredReplayCoverageMessageIDs: [String],
		didOverflow: Bool,
		hasUnsupportedContentEvidence: Bool
	) {
		self.seenMessageIDs = trustedSeenMessageIDs
		self.seenToolCallIDs = trustedSeenToolCallIDs
		self.observedMessageTextScalarCounts = trustedObservedMessageTextScalarCounts
		self.observedMessageTextDigests = trustedObservedMessageTextDigests
		self.requiredReplayCoverageMessageIDs = trustedRequiredReplayCoverageMessageIDs
		self.terminalToolCallIDs = trustedTerminalToolCallIDs
		self.didOverflow = didOverflow
		self.hasUnsupportedContentEvidence = hasUnsupportedContentEvidence
		self.lastEventOrdinal = lastEventOrdinal
	}

	private enum CodingKeys: String, CodingKey {
		case seenMessageIDs
		case seenToolCallIDs
		case contentEvidenceVersion
		case observedMessageTextScalarCounts
		case observedMessageTextDigests
		case requiredReplayCoverageMessageIDs
		case terminalToolCallIDs
		case didOverflow
		case hasUnsupportedContentEvidence
		case lastEventOrdinal
		// Version-1 keys, decoded ONLY to detect that a legacy record carried content
		// evidence. Their values are never reinterpreted under version-2 semantics.
		case observedMessageTextLengths
		case observedMessageTextChecksums
	}

	/// Upper bound on recorded coverage for a single message. Beyond this the record is
	/// not a plausible transcript frontier and is treated as unsupported rather than
	/// trusted.
	public static let maxObservedTextScalars = 1 << 24

	/// Persisted frontiers are UNTRUSTED input (sixth round, finding 1). Decoding
	/// validates every invariant the replay reconciler relies on and fails CLOSED —
	/// marking the record unsupported so planner and runner refuse before consuming a
	/// recovery attempt — rather than silently filtering a malformed record into
	/// something that looks usable. In particular:
	///
	///   * a missing version key is only legitimate for a genuinely PRE-evidence
	///     record; a record with no version but version-2 fields is a forgery or a
	///     corruption, never evidence to act on;
	///   * coverage counts must be non-negative and bounded — a negative required
	///     coverage would compare as already-satisfied and let an unproven replay
	///     deliver in full;
	///   * every positive coverage record needs digest evidence whose absorbed byte
	///     count is UTF-8-consistent with it (1–4 bytes per scalar), and a digest with
	///     no coverage record is equally inconsistent;
	///   * coverage, digest, and required-ID collections must be bounded and their keys
	///     must all be message IDs the record actually claims to have seen.
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let version = try container.decodeIfPresent(Int.self, forKey: .contentEvidenceVersion)
		let legacyLengths = try container.decodeIfPresent([String: Int].self, forKey: .observedMessageTextLengths) ?? [:]
		let legacyChecksums = try container.decodeIfPresent([String: UInt64].self, forKey: .observedMessageTextChecksums) ?? [:]
		let seenMessageIDs = try container.decodeIfPresent([String].self, forKey: .seenMessageIDs) ?? []
		let scalarCounts = try container.decodeIfPresent([String: Int].self, forKey: .observedMessageTextScalarCounts) ?? [:]
		// A malformed digest STATE throws out of `OpenCodeIncrementalSHA256.init(from:)`
		// rather than decoding into something that would trap at finalization, so a
		// whole-record decode failure is itself a fail-closed outcome.
		let digests = try container.decodeIfPresent([String: OpenCodeIncrementalSHA256].self, forKey: .observedMessageTextDigests) ?? [:]
		let required = try container.decodeIfPresent([String].self, forKey: .requiredReplayCoverageMessageIDs) ?? []

		var unsupported: Bool
		switch version {
		case .some(Self.contentEvidenceVersion):
			unsupported = false
		case .none:
			// Pre-evidence records carry no evidence of ANY generation.
			unsupported = !legacyLengths.isEmpty
				|| !legacyChecksums.isEmpty
				|| !scalarCounts.isEmpty
				|| !digests.isEmpty
				|| !required.isEmpty
		default:
			unsupported = true
		}
		// A frontier that already knew its evidence was unusable stays unusable across
		// a re-encode; the flag is sticky, never cleared by a version bump.
		if try container.decodeIfPresent(Bool.self, forKey: .hasUnsupportedContentEvidence) == true {
			unsupported = true
		}
		let seenToolCallIDs = try container.decodeIfPresent([String].self, forKey: .seenToolCallIDs) ?? []
		let terminalToolCallIDs = try container.decodeIfPresent([String].self, forKey: .terminalToolCallIDs) ?? []
		let lastEventOrdinal = try container.decodeIfPresent(Int.self, forKey: .lastEventOrdinal) ?? 0
		if !unsupported {
			unsupported = !Self.contentEvidenceIsStructurallyValid(
				seenMessageIDs: seenMessageIDs,
				seenToolCallIDs: seenToolCallIDs,
				terminalToolCallIDs: terminalToolCallIDs,
				lastEventOrdinal: lastEventOrdinal,
				scalarCounts: scalarCounts,
				digests: digests,
				required: required
			)
		}
		self.init(
			seenMessageIDs: seenMessageIDs,
			seenToolCallIDs: seenToolCallIDs,
			lastEventOrdinal: lastEventOrdinal,
			observedMessageTextScalarCounts: unsupported ? [:] : scalarCounts,
			terminalToolCallIDs: terminalToolCallIDs,
			observedMessageTextDigests: unsupported ? [:] : digests,
			requiredReplayCoverageMessageIDs: unsupported ? [] : required,
			didOverflow: try container.decodeIfPresent(Bool.self, forKey: .didOverflow) ?? false,
			hasUnsupportedContentEvidence: unsupported
		)
	}

	/// Upper bound on the persisted event ordinal. Beyond this the record is not a
	/// plausible transcript frontier.
	public static let maxEventOrdinal = 1 << 40

	/// Validates EVERY invariant the live producer maintains (seventh round, finding 2).
	/// The previous version checked only the message-side pairings, so a record could
	/// name a required message with no coverage at all, or claim a terminal tool call it
	/// never saw, and still be accepted as trustworthy evidence.
	private static func contentEvidenceIsStructurallyValid(
		seenMessageIDs: [String],
		seenToolCallIDs: [String],
		terminalToolCallIDs: [String],
		lastEventOrdinal: Int,
		scalarCounts: [String: Int],
		digests: [String: OpenCodeIncrementalSHA256],
		required: [String]
	) -> Bool {
		guard scalarCounts.count <= maxTrackedIdentifiers,
			digests.count <= maxTrackedIdentifiers,
			required.count <= maxTrackedIdentifiers,
			seenToolCallIDs.count <= maxTrackedIdentifiers,
			terminalToolCallIDs.count <= maxTrackedIdentifiers else { return false }
		guard lastEventOrdinal >= 0, lastEventOrdinal <= maxEventOrdinal else { return false }

		let seen = Set(seenMessageIDs)
		guard seen.count == seenMessageIDs.count, !seen.contains("") else { return false }
		let seenTools = Set(seenToolCallIDs)
		guard seenTools.count == seenToolCallIDs.count, !seenTools.contains("") else { return false }
		let terminals = Set(terminalToolCallIDs)
		guard terminals.count == terminalToolCallIDs.count else { return false }
		// A terminal observation for a tool call the record never saw is impossible:
		// `advanced` always records the ID before it can mark it terminal.
		guard terminals.isSubset(of: seenTools) else { return false }

		guard Set(required).count == required.count else { return false }
		guard scalarCounts.keys.allSatisfy(seen.contains),
			digests.keys.allSatisfy(seen.contains),
			required.allSatisfy(seen.contains) else { return false }
		// Coverage and digest are created together by `absorb`, for every count
		// INCLUDING zero (an observed empty chunk records a zero-byte digest), so
		// neither may appear without the other.
		guard digests.keys.allSatisfy({ scalarCounts[$0] != nil }) else { return false }
		guard scalarCounts.keys.allSatisfy({ digests[$0] != nil }) else { return false }
		// A required message with no coverage record cannot be proven or disproven; it
		// would silently drop out of the requirement loop.
		guard required.allSatisfy({ scalarCounts[$0] != nil }) else { return false }

		for (messageID, count) in scalarCounts {
			guard count >= 0, count <= maxObservedTextScalars else { return false }
			guard let digest = digests[messageID], !digest.isSaturated else { return false }
			// UTF-8 encodes each scalar in 1...4 bytes.
			guard digest.byteCount >= UInt64(count), digest.byteCount <= UInt64(count) * 4 else { return false }
		}
		return true
	}

	/// Encodes version-2 evidence only. Legacy keys are never written, so a record
	/// written by this build is never mistaken for a version-1 record.
	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(seenMessageIDs, forKey: .seenMessageIDs)
		try container.encode(seenToolCallIDs, forKey: .seenToolCallIDs)
		try container.encode(Self.contentEvidenceVersion, forKey: .contentEvidenceVersion)
		try container.encode(observedMessageTextScalarCounts, forKey: .observedMessageTextScalarCounts)
		try container.encode(observedMessageTextDigests, forKey: .observedMessageTextDigests)
		try container.encode(requiredReplayCoverageMessageIDs, forKey: .requiredReplayCoverageMessageIDs)
		try container.encode(terminalToolCallIDs, forKey: .terminalToolCallIDs)
		try container.encode(didOverflow, forKey: .didOverflow)
		try container.encode(hasUnsupportedContentEvidence, forKey: .hasUnsupportedContentEvidence)
		try container.encode(lastEventOrdinal, forKey: .lastEventOrdinal)
	}

	/// Advances the frontier with one observed update. `observedTextChunk` nil means
	/// "no rendered-text information" — the message ID is recorded for whole-message
	/// dedup but no length/checksum entry is touched (distinct from an observed empty
	/// chunk, which records length 0). Suppressed replays advance with nil so lengths
	/// and checksums never double-count. An identifier that cannot be recorded within
	/// the bound marks the frontier overflowed instead of being silently dropped.
	public func advanced(
		messageID: String?,
		toolCallID: String?,
		observedTextChunk: String? = nil,
		toolCallReachedTerminal: Bool = false
	) -> OpenCodeTranscriptFrontier {
		var messages = seenMessageIDs
		var tools = seenToolCallIDs
		var scalarCounts = observedMessageTextScalarCounts
		var digests = observedMessageTextDigests
		var required = requiredReplayCoverageMessageIDs
		var terminals = terminalToolCallIDs
		var overflowed = didOverflow
		// Coverage accounting is in unicode scalars and the content digest absorbs UTF-8
		// bytes: both are additive across arbitrary chunk boundaries, so the same text
		// split differently reaches the same count and the same digest state.
		// Live bounds are CHECKED and fail closed (seventh round, finding 2). Unchecked
		// addition here could both trap and, more insidiously, carry a supported
		// frontier past `maxObservedTextScalars` while `didOverflow` stayed false — so
		// automatic recovery would proceed on state the decoder itself would later
		// reject. On any exceeded bound the already-trusted state is RETAINED unchanged
		// and the frontier is marked overflowed, which the runner already refuses on.
		func absorb(_ chunk: String, into messageID: String, startingFresh: Bool) {
			let base = startingFresh ? 0 : (scalarCounts[messageID] ?? 0)
			let (sum, addOverflow) = base.addingReportingOverflow(chunk.unicodeScalars.count)
			guard !addOverflow, sum <= Self.maxObservedTextScalars else {
				overflowed = true
				return
			}
			var digest = startingFresh ? OpenCodeIncrementalSHA256() : (digests[messageID] ?? OpenCodeIncrementalSHA256())
			digest.update(utf8: chunk)
			guard !digest.isSaturated else {
				overflowed = true
				return
			}
			scalarCounts[messageID] = sum
			digests[messageID] = digest
			// Observing text for a message means it is (still) streaming: a replay must
			// prove it covered this prefix until the turn that owns it completes.
			if !required.contains(messageID), required.count < Self.maxTrackedIdentifiers {
				required.append(messageID)
			} else if !required.contains(messageID) {
				overflowed = true
			}
		}
		if let messageID, !messageID.isEmpty {
			if messages.contains(messageID) {
				if let observedTextChunk {
					absorb(observedTextChunk, into: messageID, startingFresh: false)
				}
			} else if messages.count < Self.maxTrackedIdentifiers {
				messages.append(messageID)
				if let observedTextChunk {
					absorb(observedTextChunk, into: messageID, startingFresh: true)
				}
			} else {
				overflowed = true
			}
		}
		if let toolCallID, !toolCallID.isEmpty {
			if !tools.contains(toolCallID) {
				if tools.count < Self.maxTrackedIdentifiers {
					tools.append(toolCallID)
				} else {
					overflowed = true
				}
			}
			if toolCallReachedTerminal, !terminals.contains(toolCallID) {
				if terminals.count < Self.maxTrackedIdentifiers {
					terminals.append(toolCallID)
				} else {
					overflowed = true
				}
			}
		}
		// The ordinal is bounded too: exceeding it marks the frontier overflowed rather
		// than wrapping or trapping.
		var nextOrdinal = lastEventOrdinal
		let (advancedOrdinal, ordinalOverflow) = lastEventOrdinal.addingReportingOverflow(1)
		if ordinalOverflow || advancedOrdinal > Self.maxEventOrdinal {
			overflowed = true
		} else {
			nextOrdinal = advancedOrdinal
		}
		return OpenCodeTranscriptFrontier(
			trustedSeenMessageIDs: messages,
			trustedSeenToolCallIDs: tools,
			lastEventOrdinal: nextOrdinal,
			trustedObservedMessageTextScalarCounts: scalarCounts,
			trustedTerminalToolCallIDs: terminals,
			trustedObservedMessageTextDigests: digests,
			trustedRequiredReplayCoverageMessageIDs: required,
			didOverflow: overflowed,
			hasUnsupportedContentEvidence: hasUnsupportedContentEvidence
		)
	}

	/// Clears the replay-coverage requirement (fifth round, finding 2). Called at a
	/// COMPLETED turn boundary only: the messages that turn produced are finished, and
	/// a later `session/load` is free to return history sparsely for them. Messages
	/// still streaming when the transport dies never reach this point, so their
	/// requirement survives into recovery.
	public func clearingRequiredReplayCoverage() -> OpenCodeTranscriptFrontier {
		OpenCodeTranscriptFrontier(
			trustedSeenMessageIDs: seenMessageIDs,
			trustedSeenToolCallIDs: seenToolCallIDs,
			lastEventOrdinal: lastEventOrdinal,
			trustedObservedMessageTextScalarCounts: observedMessageTextScalarCounts,
			trustedTerminalToolCallIDs: terminalToolCallIDs,
			trustedObservedMessageTextDigests: observedMessageTextDigests,
			trustedRequiredReplayCoverageMessageIDs: [],
			didOverflow: didOverflow,
			hasUnsupportedContentEvidence: hasUnsupportedContentEvidence
		)
	}

	/// True when a replayed update refers to content already in the RepoPrompt
	/// transcript and must be dropped during load recovery.
	public func containsReplay(messageID: String?, toolCallID: String?) -> Bool {
		if let messageID, !messageID.isEmpty, seenMessageIDs.contains(messageID) {
			return true
		}
		if let toolCallID, !toolCallID.isEmpty, seenToolCallIDs.contains(toolCallID) {
			return true
		}
		return false
	}

	/// Cumulative observed text coverage for a message in UNICODE SCALARS, or nil when
	/// the frontier has no coverage record (pre-coverage frontier or unseen message).
	public func observedTextScalarCount(forMessageID messageID: String) -> Int? {
		observedMessageTextScalarCounts[messageID]
	}

	/// Resumable content digest of the cumulative observed text for a message, or nil
	/// when no content evidence was recorded.
	public func observedTextDigest(forMessageID messageID: String) -> OpenCodeIncrementalSHA256? {
		observedMessageTextDigests[messageID]
	}

	/// True when a recovery replay must prove it covered this message's rendered
	/// prefix; a replay that omits it, or covers it only with empty chunks, is a
	/// refusal rather than a success.
	public func requiresReplayCoverage(forMessageID messageID: String) -> Bool {
		requiredReplayCoverageMessageIDs.contains(messageID)
	}

	/// True when the tool call's terminal update was observed before the frontier.
	public func sawTerminal(forToolCallID toolCallID: String) -> Bool {
		terminalToolCallIDs.contains(toolCallID)
	}
}

public enum OpenCodeRecoveryRefusalReason: Hashable, Sendable, CustomStringConvertible {
	case attemptAlreadyMade
	case workspaceRootChanged(persisted: String, current: String)
	case runtimeUnresolvable(OpenCodeRuntimeUnresolvableReason)
	case runtimeNotAdmitted
	case noRecoveryCapability
	case sessionIdentityMissing
	case frontierContentEvidenceUnsupported
	case frontierOverflowed

	public var description: String {
		switch self {
		case .attemptAlreadyMade: return "a recovery attempt was already made for this transport loss"
		case .workspaceRootChanged(let persisted, let current): return "workspace root changed (was \(persisted), now \(current))"
		case .runtimeUnresolvable(let reason): return "runtime identity unresolvable: \(reason.rawValue)"
		case .runtimeNotAdmitted: return "replacement runtime was not admitted"
		case .noRecoveryCapability: return "runtime advertises neither resume nor load"
		case .sessionIdentityMissing: return "no provider session identity was persisted"
		case .frontierContentEvidenceUnsupported:
			return "the persisted transcript frontier carries content evidence this build cannot interpret"
		case .frontierOverflowed:
			return "the transcript frontier exceeded its bound, so replay deduplication cannot be proven faithful"
		}
	}
}

public enum OpenCodeSessionRecoveryPlan: Hashable, Sendable {
	/// `session/resume`: same provider session, no full replay expected.
	case resume(sessionID: String)
	/// `session/load` with replay deduplicated against the frontier.
	case loadWithReplayDeduplication(sessionID: String, frontier: OpenCodeTranscriptFrontier)
	/// Automatic recovery stops; the UI offers an explicit new-session handoff that is
	/// visibly distinct from resume.
	case refuse(OpenCodeRecoveryRefusalReason)
}

public struct OpenCodeSessionRecoveryContext {
	public let record: OpenCodeSessionRecoveryRecord?
	public let currentCanonicalRootPath: String
	public let currentRuntime: OpenCodeRuntimeResolution
	/// Fresh admission decision for the replacement runtime (re-resolve and re-admit is
	/// mandatory; a prior observation can never stand in for it).
	public let admissionDecision: OpenCodeAdmissionDecision
	public let effectiveCapabilities: OpenCodeEffectiveSessionCapabilities
	public let recoveryAttemptsMade: Int

	public init(
		record: OpenCodeSessionRecoveryRecord?,
		currentCanonicalRootPath: String,
		currentRuntime: OpenCodeRuntimeResolution,
		admissionDecision: OpenCodeAdmissionDecision,
		effectiveCapabilities: OpenCodeEffectiveSessionCapabilities,
		recoveryAttemptsMade: Int
	) {
		self.record = record
		self.currentCanonicalRootPath = currentCanonicalRootPath
		self.currentRuntime = currentRuntime
		self.admissionDecision = admissionDecision
		self.effectiveCapabilities = effectiveCapabilities
		self.recoveryAttemptsMade = recoveryAttemptsMade
	}
}

public enum OpenCodeSessionRecoveryPlanner {
	public static func plan(_ context: OpenCodeSessionRecoveryContext) -> OpenCodeSessionRecoveryPlan {
		guard let record = context.record, !record.providerSessionID.isEmpty else {
			return .refuse(.sessionIdentityMissing)
		}
		// Fail closed on a frontier that cannot support faithful replay dedup, BEFORE
		// anything else consumes the attempt (fifth round, findings 1 and 3): evidence
		// this build cannot interpret, or a frontier that forgot identifiers.
		guard !record.frontier.hasUnsupportedContentEvidence else {
			return .refuse(.frontierContentEvidenceUnsupported)
		}
		guard !record.frontier.didOverflow else {
			return .refuse(.frontierOverflowed)
		}
		// At most one capability-gated recovery attempt per transport loss.
		guard context.recoveryAttemptsMade == 0 else {
			return .refuse(.attemptAlreadyMade)
		}
		// Recovery refuses implicit workspace rebinding.
		guard record.canonicalRootPath == context.currentCanonicalRootPath else {
			return .refuse(.workspaceRootChanged(
				persisted: record.canonicalRootPath,
				current: context.currentCanonicalRootPath
			))
		}
		guard case .resolved(let identity) = context.currentRuntime else {
			if case .unresolvable(let reason) = context.currentRuntime {
				return .refuse(.runtimeUnresolvable(reason))
			}
			return .refuse(.runtimeUnresolvable(.noCommand))
		}
		// A changed binary stops automatic recovery unless the fresh admission decision
		// explicitly admits it (certified or behavioral). Observe-only admission is
		// sufficient only when the bytes are PROVEN unchanged.
		//
		// Absence of proof is not proof (eighth round, finding 3): the previous
		// expression computed `bytesChanged` only when a digest existed, so a record
		// with `runtimeSHA256Hex` omitted — or carrying a malformed value — took the
		// unchanged path and observe-only recovery proceeded against an unverified
		// binary. A missing or unparseable digest now counts as changed, which under
		// observe-only means refuse.
		let recordedDigest = record.runtimeSHA256Hex.flatMap { OpenCodeSHA256($0) }
		let bytesChanged = recordedDigest?.value != identity.sha256.value
		switch context.admissionDecision {
		case .admitCertified, .admitBehavioral:
			break
		case .admitObserveOnly:
			if bytesChanged {
				return .refuse(.runtimeNotAdmitted)
			}
		case .reject:
			return .refuse(.runtimeNotAdmitted)
		}

		if context.effectiveCapabilities.resumeSession {
			return .resume(sessionID: record.providerSessionID)
		}
		if context.effectiveCapabilities.loadSession {
			return .loadWithReplayDeduplication(
				sessionID: record.providerSessionID,
				frontier: record.frontier
			)
		}
		return .refuse(.noRecoveryCapability)
	}
}

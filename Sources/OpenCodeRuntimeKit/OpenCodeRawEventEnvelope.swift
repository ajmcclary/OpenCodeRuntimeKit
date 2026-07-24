import Foundation

// Pre-normalization envelope accounting (NOW-2).
//
// Every raw ACP frame gets an envelope with a monotonic sequence, direction, and
// classification. Acceptance requires 100% accounting: every inbound envelope is
// normalized, intentionally suppressed WITH a reason, or preserved as opaque-unknown.
// Terminal failures are never suppressed.

public enum OpenCodeEnvelopeDirection: String, Hashable, Sendable {
	case inbound
	case outbound
}

public enum OpenCodeEnvelopeKind: String, Hashable, Sendable {
	case request
	case response
	case notification
	case invalid
}

/// Classification of what normalization did with one inbound envelope.
public enum OpenCodeEnvelopeDisposition: Hashable, Sendable {
	case normalized(eventCount: Int)
	case suppressed(reason: OpenCodeSuppressionReason)
	case opaqueUnknown
	/// Outbound and non-session frames that normalization never sees.
	case notApplicable
}

/// Closed vocabulary of intentional suppression reasons. A drop without one of these
/// reasons is an accounting defect.
public enum OpenCodeSuppressionReason: String, Hashable, Sendable, CaseIterable {
	case sessionLoadReplay
	case lowLevelToolNoise
	case statusTitleNoise
	case emptyPayload
	case duplicateEvent
	case lateEventAfterTerminal
	case profileSuppressedToolEvent
	/// Update types the product deliberately never surfaces (e.g. available-commands,
	/// plan, echoed user chunks).
	case intentionallyUnsurfacedType
	/// Provider-internal buffering consumed the update and will re-emit it later
	/// (e.g. Gemini structured-thought coalescing).
	case providerInternalBuffering
	/// The frame carried no session identity, or an identity that is not this
	/// controller's active session. Tenth round, finding 2: such a frame is refused
	/// before it can reach the transcript, the frontier, usage state, or an approval —
	/// it is neither a normalized event nor an intentional product suppression, so it
	/// gets its own reason rather than borrowing one.
	case foreignSessionIdentity
}

/// One bounded, metadata-only envelope record. Payload BYTES never enter this type —
/// only shape metadata (size, method, ids) — so the record is safe for bounded support
/// traces after redaction of the identifier fields.
public struct OpenCodeRawEventEnvelope: Hashable, Sendable {
	public let sequence: UInt64
	public let direction: OpenCodeEnvelopeDirection
	public let kind: OpenCodeEnvelopeKind
	public let method: String?
	public let requestID: String?
	public let sessionID: String?
	public let sessionUpdateType: String?
	public let payloadByteCount: Int
	public let disposition: OpenCodeEnvelopeDisposition

	public init(
		sequence: UInt64,
		direction: OpenCodeEnvelopeDirection,
		kind: OpenCodeEnvelopeKind,
		method: String?,
		requestID: String?,
		sessionID: String?,
		sessionUpdateType: String?,
		payloadByteCount: Int,
		disposition: OpenCodeEnvelopeDisposition
	) {
		self.sequence = sequence
		self.direction = direction
		self.kind = kind
		self.method = method
		self.requestID = requestID
		self.sessionID = sessionID
		self.sessionUpdateType = sessionUpdateType
		self.payloadByteCount = payloadByteCount
		self.disposition = disposition
	}
}

/// Aggregated per-run envelope accounting. `unreasonedDrops` must be zero in supported
/// fixtures; a nonzero value means an envelope disappeared without classification.
public struct OpenCodeEnvelopeAccounting: Hashable, Sendable {
	public private(set) var inboundTotal: Int = 0
	public private(set) var outboundTotal: Int = 0
	public private(set) var normalized: Int = 0
	public private(set) var suppressed: [OpenCodeSuppressionReason: Int] = [:]
	public private(set) var opaqueUnknown: Int = 0
	public private(set) var invalid: Int = 0
	public private(set) var unreasonedDrops: Int = 0
	public private(set) var lastSequence: UInt64 = 0
	public private(set) var sequenceRegressions: Int = 0

	public init() {}

	public mutating func record(_ envelope: OpenCodeRawEventEnvelope) {
		if envelope.sequence <= lastSequence, envelope.sequence != 0 || lastSequence != 0 {
			if envelope.sequence <= lastSequence, inboundTotal + outboundTotal > 0 {
				sequenceRegressions += 1
			}
		}
		lastSequence = max(lastSequence, envelope.sequence)

		switch envelope.direction {
		case .inbound:
			inboundTotal += 1
		case .outbound:
			outboundTotal += 1
		}

		if envelope.kind == .invalid {
			invalid += 1
		}

		switch envelope.disposition {
		case .normalized(let count):
			normalized += 1
			if count == 0 {
				// Zero events from a "normalized" envelope is an unreasoned drop.
				unreasonedDrops += 1
			}
		case .suppressed(let reason):
			suppressed[reason, default: 0] += 1
		case .opaqueUnknown:
			opaqueUnknown += 1
		case .notApplicable:
			break
		}
	}

	public var suppressedTotal: Int {
		suppressed.values.reduce(0, +)
	}

	/// True when every inbound session envelope is accounted for.
	public var isFullyAccounted: Bool {
		unreasonedDrops == 0
	}
}

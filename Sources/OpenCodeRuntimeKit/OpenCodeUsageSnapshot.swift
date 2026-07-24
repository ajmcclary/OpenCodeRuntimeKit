import Foundation

/// Nullable, provenance-preserving usage accounting for one OpenCode turn (NOW-2).
///
/// Missing values stay unknown (nil), never zero. Raw provider usage payloads are
/// preserved as serialized provenance so no field is silently invented. Aggregation
/// merges only fields proven additive.
public struct OpenCodeUsageSnapshot: Hashable, Sendable {
	public enum Source: String, Hashable, Sendable {
		case promptResponse
		case usageUpdate
	}

	/// One contributing usage payload with the wire surface it came from.
	///
	/// NORMALIZED provenance, not a byte-faithful capture (eighth round, finding 5):
	/// the payload has already been through `JSONSerialization` by the time it reaches
	/// this type, so numeric lexemes may have been re-rendered and values beyond a
	/// `Double`'s exact range may have rounded. This is the sorted-keys serialization of
	/// the PARSED object, which is faithful evidence of what RepoPrompt actually saw —
	/// it is deliberately not claimed to be the original bytes.
	/// Maximum UTF-8 bytes of raw provenance retained PER entry (thirteenth round,
	/// finding 6). The twelfth round bounded provenance by ENTRY COUNT only, but each
	/// `rawJSON` could approach the ACP line limit (megabytes), and up to
	/// `maxRetainedProvenanceEntries` entries were retained for up to eight finalized
	/// sessions — a hostile provider could keep hundreds of MB of normalized JSON alive.
	/// A larger payload is truncated to a bounded PREVIEW plus a digest of the full bytes,
	/// so the rejected values stay visible as evidence without retaining them verbatim.
	public static let maxProvenanceEntryPreviewBytes = 4096

	/// The concrete maximum retained provenance bytes across one snapshot's trail.
	public static var maxRetainedProvenanceBytes: Int {
		maxRetainedProvenanceEntries * maxProvenanceEntryPreviewBytes
	}

	public struct ProvenanceEntry: Hashable, Sendable {
		public let source: Source
		/// A BYTE-BOUNDED preview of the normalized payload (≤ `maxProvenanceEntryPreviewBytes`
		/// UTF-8 bytes; a truncation marker is appended when the original was larger).
		public let rawJSON: String?
		/// UTF-8 byte count of the ORIGINAL (pre-truncation) payload.
		public let originalByteCount: Int
		/// SHA-256 of the original payload bytes — evidence of the full content even when
		/// only a preview is retained.
		public let digestHex: String?

		public var isTruncated: Bool {
			(rawJSON?.utf8.count ?? 0) < originalByteCount
		}

		public init(source: Source, rawJSON: String?) {
			self.source = source
			let bounded = OpenCodeUsageSnapshot.boundedProvenance(rawJSON)
			self.rawJSON = bounded.preview
			self.originalByteCount = bounded.originalByteCount
			self.digestHex = bounded.digestHex
		}
	}

	/// Truncates a raw provenance payload to a bounded UTF-8 preview (on a scalar
	/// boundary), appends a compact truncation marker, and fingerprints the full bytes.
	/// The returned preview is always ≤ `maxProvenanceEntryPreviewBytes` UTF-8 bytes.
	static func boundedProvenance(_ raw: String?) -> (preview: String?, originalByteCount: Int, digestHex: String?) {
		guard let raw else { return (nil, 0, nil) }
		let originalBytes = Data(raw.utf8)
		let originalByteCount = originalBytes.count
		guard originalByteCount > maxProvenanceEntryPreviewBytes else {
			return (raw, originalByteCount, nil)
		}
		let digest = OpenCodeSHA256Digest.digest(of: originalBytes).value
		// Reserve room for the marker so the final preview never exceeds the bound.
		let markerReserve = 48
		var previewData = originalBytes.prefix(max(0, maxProvenanceEntryPreviewBytes - markerReserve))
		while !previewData.isEmpty && String(data: previewData, encoding: .utf8) == nil {
			previewData = previewData.dropLast()
		}
		let previewBody = String(data: previewData, encoding: .utf8) ?? ""
		let droppedBytes = originalByteCount - previewBody.utf8.count
		let preview = previewBody + "…[+\(droppedBytes)B sha256:\(digest.prefix(12))]"
		return (preview, originalByteCount, digest)
	}

	/// Exactly the fields a usage EVENT can express downstream (see
	/// `OpenCodeACPEventNormalizer.finalUsageEvents`, whose payload reaches
	/// `AIStreamResult` through `ACPDefaultSessionUpdateNormalizer`). Duplicate
	/// suppression must compare this and nothing else (fifth round, finding 5):
	/// comparing whole snapshots meant a prompt-response payload carrying values
	/// identical to what was already emitted still differed — by `source` and by raw
	/// provenance — and the same visible usage event was emitted twice.
	///
	/// `costCurrency` is deliberately NOT here (sixth round, finding 5). It was, and
	/// that reintroduced the very defect this type exists to fix: `AIStreamResult`
	/// carries only the numeric cost, so 0.25 USD and 0.25 EUR compare unequal here
	/// while producing byte-identical downstream events. Currency stays in the
	/// snapshot and in the retained evidence, where it is not a duplicate; it is
	/// simply not part of what the visible event can say.
	public struct SemanticProjection: Hashable, Sendable {
		public let contextUsedTokens: Int?
		public let contextWindowTokens: Int?
		public let costAmount: Double?

		/// True when the projection would produce a usage event carrying no usage
		/// information at all; such an event is never worth emitting.
		public var isEmpty: Bool {
			contextUsedTokens == nil && contextWindowTokens == nil && costAmount == nil
		}
	}

	/// Bound on retained raw provenance per snapshot. Beyond it the trail keeps the
	/// earliest entries plus the most recent one and reports how many it dropped, so
	/// truncation is visible rather than silent.
	public static let maxRetainedProvenanceEntries = 8

	/// Documented conservative policy for a provider-supplied currency identifier
	/// (fourteenth round, finding 3). `decode` used to store
	/// `costObject["currency"] as? String` UNBOUNDED — the one provider-controlled scalar
	/// String on this type that bypassed every byte bound, surviving `merging(latest:)`
	/// and the finalized-session evidence cache. A currency identifier is an ISO-4217
	/// code, a crypto ticker, a currency symbol, or a short product word ("credits"):
	/// at most `maxCostCurrencyScalars` Unicode scalars and `maxCostCurrencyUTF8Bytes`
	/// UTF-8 bytes, every scalar a letter, decimal digit, or currency symbol — no
	/// controls, no whitespace, no format/bidi characters, no punctuation.
	public static let maxCostCurrencyUTF8Bytes = 16
	public static let maxCostCurrencyScalars = 8

	/// The policy gate, enforced at the DESIGNATED initializer so no construction path —
	/// decode, merge, or direct init — can retain an out-of-policy value. A rejected
	/// value is unknown (nil); its evidence survives only through the already-bounded
	/// provenance preview + digest.
	static func boundedCostCurrency(_ raw: String?) -> String? {
		guard let raw, !raw.isEmpty else { return nil }
		guard raw.utf8.count <= maxCostCurrencyUTF8Bytes,
			raw.unicodeScalars.count <= maxCostCurrencyScalars else { return nil }
		for scalar in raw.unicodeScalars {
			switch scalar.properties.generalCategory {
			case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter,
				.decimalNumber, .currencySymbol:
				continue
			default:
				return nil
			}
		}
		return raw
	}

	public let inputTokens: Int?
	public let outputTokens: Int?
	public let reasoningTokens: Int?
	public let cacheReadTokens: Int?
	public let cacheWriteTokens: Int?
	public let contextUsedTokens: Int?
	public let contextWindowTokens: Int?
	public let costAmount: Double?
	public let costCurrency: String?
	/// The source of the MOST RECENT contributing payload. For a snapshot built from
	/// more than one surface this is not the whole truth — `contributingSources` and
	/// `isMixedSource` are (fifth round, finding 6).
	public let source: Source
	/// Every raw usage payload that contributed to this snapshot, oldest first,
	/// bounded and deduplicated. A usage update supplying context followed by a prompt
	/// response supplying cost keeps BOTH payloads; previously the later one replaced
	/// the earlier and its provenance was lost.
	public let provenanceTrail: [ProvenanceEntry]
	/// Number of contributing payloads dropped by the retention bound.
	public let droppedProvenanceCount: Int
	/// Every wire surface that contributed, in first-contribution order — recorded
	/// INDEPENDENTLY of the retained raw payloads (sixth round, finding 7).
	///
	/// Deriving this from `provenanceTrail` meant bounding the raw payloads could erase
	/// source-level truth: once the trail's only `promptResponse` entry fell in the
	/// dropped middle, a snapshot still carrying fields supplied by that response
	/// reported `[.usageUpdate]` and `isMixedSource == false`. Raw payloads are
	/// lossy by design; which surfaces contributed is not, and the closed `Source`
	/// enum bounds this list at two entries anyway.
	public let contributingSources: [Source]

	/// Sorted-keys serialization of the most recent PARSED usage object. See
	/// `ProvenanceEntry` — normalized evidence, not the original wire bytes.
	public var rawProvenanceJSON: String? { provenanceTrail.last?.rawJSON }

	/// Total UTF-8 bytes of retained provenance previews across this snapshot's trail —
	/// always ≤ `maxRetainedProvenanceBytes` (thirteenth round, finding 6).
	public var retainedProvenanceByteCount: Int {
		provenanceTrail.reduce(0) { $0 + ($1.rawJSON?.utf8.count ?? 0) }
	}

	public var isMixedSource: Bool { contributingSources.count > 1 }

	public var semanticProjection: SemanticProjection {
		SemanticProjection(
			contextUsedTokens: contextUsedTokens,
			contextWindowTokens: contextWindowTokens,
			costAmount: costAmount
		)
	}

	public init(
		inputTokens: Int?,
		outputTokens: Int?,
		reasoningTokens: Int?,
		cacheReadTokens: Int?,
		cacheWriteTokens: Int?,
		contextUsedTokens: Int?,
		contextWindowTokens: Int?,
		costAmount: Double?,
		costCurrency: String?,
		source: Source,
		rawProvenanceJSON: String?
	) {
		self.init(
			inputTokens: inputTokens,
			outputTokens: outputTokens,
			reasoningTokens: reasoningTokens,
			cacheReadTokens: cacheReadTokens,
			cacheWriteTokens: cacheWriteTokens,
			contextUsedTokens: contextUsedTokens,
			contextWindowTokens: contextWindowTokens,
			costAmount: costAmount,
			costCurrency: costCurrency,
			source: source,
			provenanceTrail: [ProvenanceEntry(source: source, rawJSON: rawProvenanceJSON)],
			droppedProvenanceCount: 0,
			contributingSources: [source]
		)
	}

	public init(
		inputTokens: Int?,
		outputTokens: Int?,
		reasoningTokens: Int?,
		cacheReadTokens: Int?,
		cacheWriteTokens: Int?,
		contextUsedTokens: Int?,
		contextWindowTokens: Int?,
		costAmount: Double?,
		costCurrency: String?,
		source: Source,
		provenanceTrail: [ProvenanceEntry],
		droppedProvenanceCount: Int,
		contributingSources: [Source]
	) {
		self.inputTokens = inputTokens
		self.outputTokens = outputTokens
		self.reasoningTokens = reasoningTokens
		self.cacheReadTokens = cacheReadTokens
		self.cacheWriteTokens = cacheWriteTokens
		self.contextUsedTokens = contextUsedTokens
		self.contextWindowTokens = contextWindowTokens
		self.costAmount = costAmount
		// Provider-controlled scalar; policy-gated at the choke point (fourteenth round,
		// finding 3) so merging and finalized-cache retention can never reintroduce an
		// out-of-policy value.
		self.costCurrency = Self.boundedCostCurrency(costCurrency)
		self.source = source
		self.provenanceTrail = provenanceTrail
		self.droppedProvenanceCount = droppedProvenanceCount
		self.contributingSources = contributingSources
	}

	/// First-contribution-ordered union of two source lists. Bounded by the closed
	/// `Source` enum, so this can never grow.
	static func unionedSources(_ first: [Source], _ second: [Source]) -> [Source] {
		var union = first
		for source in second where !union.contains(source) {
			union.append(source)
		}
		return union
	}

	/// Deterministic bounded retention: dedup identical (source, payload) pairs, keep
	/// the earliest entries and ALWAYS the most recent one, and report the rest as
	/// dropped rather than pretending they never existed.
	static func boundedTrail(_ entries: [ProvenanceEntry]) -> (trail: [ProvenanceEntry], dropped: Int) {
		var deduped: [ProvenanceEntry] = []
		for entry in entries where !deduped.contains(entry) {
			deduped.append(entry)
		}
		guard deduped.count > maxRetainedProvenanceEntries else { return (deduped, 0) }
		let head = Array(deduped.prefix(maxRetainedProvenanceEntries - 1))
		let last = deduped[deduped.count - 1]
		return (head + [last], deduped.count - maxRetainedProvenanceEntries)
	}

	/// Decodes a raw usage object. Unknown fields remain in provenance; absent fields are
	/// nil (never coerced to zero).
	public static func decode(usageObject: [String: Any], source: Source) -> OpenCodeUsageSnapshot {
		// ONE policy for every untrusted JSON number on this path
		// (`OpenCodeJSONNumberPolicy`, ninth round finding 1). This type used to own a
		// private copy while three other shipping parsers kept their own trapping
		// versions; parallel parsers for the same wire values is exactly how `1e300`
		// reached `Int(Double)` and aborted the host.
		//
		// SEMANTIC usage domain, not just exact-integer parsing (twelfth round,
		// finding 7): `nonNegativeCount` correctly admits an exact `Int.max`, but a
		// usage_update carrying `used = Int.max` then survived accumulation and was
		// published downstream as the session's exact context occupancy. No context
		// window is 9.2e18 tokens — an out-of-domain count is unknown, never a reading.
		// The rejected raw value stays visible in the provenance trail below.
		func int(_ keys: [String]) -> Int? {
			for key in keys {
				if let parsed = OpenCodeJSONNumberPolicy.boundedUsageCount(usageObject[key]) { return parsed }
			}
			return nil
		}
		func double(_ keys: [String]) -> Double? {
			for key in keys {
				if let parsed = OpenCodeJSONNumberPolicy.nonNegativeFiniteDouble(usageObject[key]) { return parsed }
			}
			return nil
		}

		var costAmount = double(["cost"])
		var costCurrency: String?
		if let costObject = usageObject["cost"] as? [String: Any] {
			// Same validation as the flat form: booleans, negatives, and non-finite
			// amounts are unknown, not zero and not NaN. The currency string is
			// policy-gated by `boundedCostCurrency` at the designated initializer
			// (fourteenth round, finding 3).
			costAmount = OpenCodeJSONNumberPolicy.nonNegativeFiniteDouble(costObject["amount"])
			costCurrency = costObject["currency"] as? String
		}

		// Normalized provenance: the serialization of what was parsed.
		let provenance: String?
		if JSONSerialization.isValidJSONObject(usageObject),
			let data = try? JSONSerialization.data(withJSONObject: usageObject, options: [.sortedKeys, .withoutEscapingSlashes]) {
			provenance = String(data: data, encoding: .utf8)
		} else {
			provenance = nil
		}

		return OpenCodeUsageSnapshot(
			inputTokens: int(["inputTokens", "input_tokens", "input"]),
			outputTokens: int(["outputTokens", "output_tokens", "output"]),
			reasoningTokens: int(["reasoningTokens", "reasoning_tokens", "reasoning"]),
			cacheReadTokens: int(["cachedReadTokens", "cacheReadTokens", "cache_read_tokens", "cacheRead"]),
			cacheWriteTokens: int(["cachedWriteTokens", "cacheWriteTokens", "cache_write_tokens", "cacheWrite"]),
			contextUsedTokens: int(["used", "contextUsedTokens"]),
			contextWindowTokens: int(["size", "contextWindowTokens"]),
			costAmount: costAmount,
			costCurrency: costCurrency,
			source: source,
			rawProvenanceJSON: provenance
		)
	}

	/// Merges a later snapshot over this one. Token counts are last-known-wins (OpenCode
	/// usage updates are cumulative per turn, not additive deltas); unknown never
	/// overwrites known.
	public func merging(latest: OpenCodeUsageSnapshot) -> OpenCodeUsageSnapshot {
		let (trail, dropped) = Self.boundedTrail(provenanceTrail + latest.provenanceTrail)
		return OpenCodeUsageSnapshot(
			inputTokens: latest.inputTokens ?? inputTokens,
			outputTokens: latest.outputTokens ?? outputTokens,
			reasoningTokens: latest.reasoningTokens ?? reasoningTokens,
			cacheReadTokens: latest.cacheReadTokens ?? cacheReadTokens,
			cacheWriteTokens: latest.cacheWriteTokens ?? cacheWriteTokens,
			contextUsedTokens: latest.contextUsedTokens ?? contextUsedTokens,
			contextWindowTokens: latest.contextWindowTokens ?? contextWindowTokens,
			costAmount: latest.costAmount ?? costAmount,
			costCurrency: latest.costCurrency ?? costCurrency,
			source: latest.source,
			provenanceTrail: trail,
			droppedProvenanceCount: droppedProvenanceCount + latest.droppedProvenanceCount + dropped,
			// Source truth is accumulated, never re-derived from the bounded trail.
			contributingSources: Self.unionedSources(contributingSources, latest.contributingSources)
		)
	}
}

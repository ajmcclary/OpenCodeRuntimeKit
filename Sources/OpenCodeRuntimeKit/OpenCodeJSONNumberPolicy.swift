import Foundation

/// The ONE policy for turning an untrusted JSON number into a Swift number.
///
/// Why this type exists (ninth round, finding 1): the hardened decoding added in the
/// eighth round lived only inside `OpenCodeUsageSnapshot`, while three other parsers on
/// the same shipping path — the controller's `messageStopResult`/`intValue`, the
/// OpenCode empty-prompt and no-model-token diagnostics, and
/// `ACPDefaultSessionUpdateNormalizer.normalizeUsageUpdate` — kept their own
/// `Int(double)` / `NSNumber.intValue` conversions. `Int(someDouble)` TRAPS outside
/// `Int`'s range, so a legal provider payload carrying `1e300` aborted the host process
/// (Swift fatal error, exit 5) even though the "hardened" type would have rejected it.
/// Parallel parsers for the same wire values are how that happens, so there is now one.
///
/// The policy, in one place:
///
///   * a JSON boolean is never a number (Foundation bridges it to `NSNumber`, where
///     `intValue` yields 0/1 — a fabricated reading);
///   * integer-backed values convert exactly and range-checked, never clamped;
///   * floating-backed values must be finite, integral, and within the safe-integer
///     range, because beyond 2^53 - 1 an adjacent integer may already have rounded onto
///     the value, so it is not evidence of the provider's actual number;
///   * strings are accepted only in one canonical spelling (ASCII decimal digits), so
///     `"+1"`, `"01"`, `"1e0"`, and whitespace variants are unknown rather than guessed;
///   * anything rejected is `nil` — unknown — and is never truncated, rounded, clamped,
///     or turned into zero.
public enum OpenCodeJSONNumberPolicy {
	/// Largest integer a `Double` represents unambiguously.
	public static let maxSafeIntegerInDouble = 9_007_199_254_740_991

	/// Domain bound for a single provider-reported token/usage count.
	///
	/// Eleventh round, finding 1: `nonNegativeCount` correctly accepts an exact
	/// integer-backed `Int.max` — that is the right contract for a general exact-integer
	/// parser — but a usage payload of `inputTokens = Int.max, cachedReadTokens = 1` then
	/// reached `max(0, a) + max(0, b)` in `messageStopResult` (and the estimator's
	/// prompt+completion sum) and TRAPPED the host on overflow. A token count near
	/// `Int.max` is not evidence of the provider's real usage — no context window is 9.2e18
	/// tokens — so a usage count is bounded at its SEMANTIC domain. Anything above the
	/// bound is unknown (`nil`), never clamped to a plausible-looking total, and the sum of
	/// a handful of counts each `≤ 1e12` cannot overflow `Int` (`Int.max ≈ 9.2e18`).
	public static let maxUsageTokenCount = 1_000_000_000_000

	/// A non-negative usage-token count within the semantic domain bound, or nil.
	/// Use this — never `nonNegativeCount` — anywhere a count will be ADDED to another.
	public static func boundedUsageCount(_ raw: Any?) -> Int? {
		guard let value = nonNegativeCount(raw) else { return nil }
		return value <= maxUsageTokenCount ? value : nil
	}

	/// Re-applies the domain bound to an already-decoded `Int` count (defense in depth for
	/// consumers that receive counts as `Int` rather than raw JSON). Out-of-domain → nil.
	public static func boundedUsageCount(_ value: Int) -> Int? {
		guard value >= 0, value <= maxUsageTokenCount else { return nil }
		return value
	}

	public static func isJSONBoolean(_ value: Any) -> Bool {
		guard let number = value as? NSNumber else { return false }
		return CFGetTypeID(number) == CFBooleanGetTypeID()
	}

	/// A non-negative integer count, or nil when the value is not exactly that.
	public static func nonNegativeCount(_ raw: Any?) -> Int? {
		guard let value = exactInteger(raw) else { return nil }
		return value >= 0 ? value : nil
	}

	/// An exactly-representable integer of either sign, or nil.
	public static func exactInteger(_ raw: Any?) -> Int? {
		guard let raw, !isJSONBoolean(raw) else { return nil }
		if let number = raw as? NSNumber {
			// The REPRESENTATION decides: `as? Int` on a floating NSNumber that
			// Foundation already rounded would bridge cleanly and look exact.
			if CFNumberIsFloatType(number) {
				return exactInteger(fromFinite: number.doubleValue)
			}
			// `int64Value` REINTERPRETS an unsigned representation rather than failing:
			// JSONSerialization parses any integer above `Int64.max` as an unsigned
			// `NSNumber` (objCType "Q"), where `18446744073709519014.int64Value` is
			// `-32602` — the JSON-RPC invalid-params code. Reading the number's own
			// decimal description and re-parsing it under the canonical string rule is
			// representation-independent: a value that does not fit `Int` exactly, in
			// either direction, is unknown rather than silently wrapped.
			return canonicalDecimalInteger(number.description)
		}
		if let value = raw as? Int { return value }
		if let value = raw as? Int64 {
			guard value >= Int64(Int.min), value <= Int64(Int.max) else { return nil }
			return Int(value)
		}
		if let value = raw as? Double { return exactInteger(fromFinite: value) }
		if let text = raw as? String { return canonicalDecimalInteger(text) }
		return nil
	}

	/// Exact, range-checked `Double` → `Int`. Never traps.
	public static func exactInteger(fromFinite value: Double) -> Int? {
		guard value.isFinite else { return nil }
		guard value == value.rounded(.towardZero) else { return nil }
		guard value >= Double(-maxSafeIntegerInDouble), value <= Double(maxSafeIntegerInDouble) else { return nil }
		return Int(value)
	}

	/// One canonical spelling only: optional `-` then ASCII decimal digits, no leading
	/// zeros beyond `"0"` itself, no `+`, no whitespace, no exponent, no decimal point.
	public static func canonicalDecimalInteger(_ text: String) -> Int? {
		var digits = Substring(text)
		var negative = false
		if digits.first == "-" {
			negative = true
			digits = digits.dropFirst()
		}
		guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
		// "01" is not a canonical spelling of 1; accepting it would let two spellings
		// alias one value.
		if digits.count > 1, digits.first == "0" { return nil }
		if negative, digits == "0" { return nil }
		return Int(negative ? "-\(digits)" : String(digits))
	}

	/// A finite, non-negative fractional quantity (cost), or nil.
	public static func nonNegativeFiniteDouble(_ raw: Any?) -> Double? {
		guard let raw, !isJSONBoolean(raw) else { return nil }
		var value: Double?
		if let number = raw as? NSNumber { value = number.doubleValue }
		else if let number = raw as? Double { value = number }
		else if let number = raw as? Int { value = Double(number) }
		else if let text = raw as? String { value = canonicalDecimalDouble(text) }
		guard let value, value.isFinite, value >= 0 else { return nil }
		return value
	}

	/// Decimal or integer spelling, no exponent, no sign gymnastics, no whitespace.
	public static func canonicalDecimalDouble(_ text: String) -> Double? {
		guard !text.isEmpty else { return nil }
		var body = Substring(text)
		if body.first == "-" { body = body.dropFirst() }
		guard !body.isEmpty else { return nil }
		let parts = body.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count <= 2 else { return nil }
		guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
		return Double(text)
	}

	/// Removes usage-shaped numeric fields the policy rejects, so a payload cannot be
	/// forwarded to another parser that might read them less carefully. Rejected values
	/// stay out of the projection; they remain visible in provenance evidence.
	/// Counts are held to the SEMANTIC usage domain (twelfth round, finding 7): an exact
	/// but out-of-domain `used = Int.max` must not ride a forwarded payload past this
	/// boundary any more than a malformed one.
	public static func sanitizedUsagePayload(_ payload: [String: Any]) -> [String: Any] {
		var sanitized = payload
		for key in ["used", "size", "inputTokens", "outputTokens", "reasoningTokens",
					"cachedReadTokens", "cachedWriteTokens", "input_tokens", "output_tokens"] {
			if let raw = sanitized[key], boundedUsageCount(raw) == nil {
				sanitized.removeValue(forKey: key)
			}
		}
		if let cost = sanitized["cost"] {
			if let object = cost as? [String: Any] {
				if nonNegativeFiniteDouble(object["amount"]) == nil {
					sanitized.removeValue(forKey: "cost")
				}
			} else if nonNegativeFiniteDouble(cost) == nil {
				sanitized.removeValue(forKey: "cost")
			}
		}
		return sanitized
	}
}

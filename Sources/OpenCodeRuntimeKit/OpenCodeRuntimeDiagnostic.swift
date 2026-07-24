import Foundation

/// Secret and path redaction for OpenCode support diagnostics.
///
/// Normal diagnostics must never persist credentials, source text, prompt text, raw
/// configuration secrets, or uncontrolled user paths. Redaction is structural (by key
/// name) plus pattern-based (token shapes, home paths) and always applied BEFORE disk.
public enum OpenCodeSecretRedactor {
	public static let redactionMarker = "«redacted»"

	/// Environment/config keys whose values are always redacted regardless of shape.
	static let sensitiveKeyFragments: [String] = [
		"password", "secret", "token", "key", "credential", "authorization", "auth", "cookie"
	]

	public static func isSensitiveKey(_ key: String) -> Bool {
		let lowered = key.lowercased()
		return sensitiveKeyFragments.contains { lowered.contains($0) }
	}

	/// Redacts a flat string map (environment, headers) by key.
	public static func redactValues(in map: [String: String]) -> [String: String] {
		var out: [String: String] = [:]
		for (key, value) in map {
			out[key] = isSensitiveKey(key) ? redactionMarker : redact(value)
		}
		return out
	}

	/// Redacts token-shaped substrings and home-directory paths in free text.
	public static func redact(_ text: String, homeDirectoryPath: String? = nil) -> String {
		var result = text
		if let home = homeDirectoryPath, !home.isEmpty, home != "/" {
			result = result.replacingOccurrences(of: home, with: "~")
		}
		result = redactPattern(in: result, pattern: #"sk-[A-Za-z0-9_-]{16,}"#)
		result = redactPattern(in: result, pattern: #"(?i)bearer\s+[A-Za-z0-9._~+/-]{16,}=*"#)
		result = redactPattern(in: result, pattern: #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#)
		result = redactPattern(in: result, pattern: #"[A-Za-z0-9+/_-]{48,}={0,2}"#)
		return result
	}

	private static func redactPattern(in text: String, pattern: String) -> String {
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
		let range = NSRange(text.startIndex..., in: text)
		return regex.stringByReplacingMatches(in: text, range: range, withTemplate: redactionMarker)
	}
}

/// One bounded, redacted support-diagnostic record. Runtime/profile identity is attached
/// so a trace always names the exact evidence row it belongs to; secrets never enter.
public struct OpenCodeRuntimeDiagnosticRecord: Hashable, Sendable {
	public let sequence: UInt64
	public let category: String
	public let message: String
	public let runtimeSHA256: String?
	public let launchProfileKeyDigest: String?
	public let contractKeyDigest: String?

	public init(
		sequence: UInt64,
		category: String,
		message: String,
		runtimeSHA256: String?,
		launchProfileKeyDigest: String?,
		contractKeyDigest: String?
	) {
		self.sequence = sequence
		self.category = category
		self.message = OpenCodeSecretRedactor.redact(message)
		self.runtimeSHA256 = runtimeSHA256
		self.launchProfileKeyDigest = launchProfileKeyDigest
		self.contractKeyDigest = contractKeyDigest
	}
}

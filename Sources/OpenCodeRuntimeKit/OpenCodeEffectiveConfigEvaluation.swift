import Foundation

// Pure evaluation of resolved OpenCode configuration (the output of
// `opencode debug config --pure` executed app-side with the exact launch executable,
// cwd, environment, and overlay). RepoPrompt does not reimplement OpenCode's merge
// pipeline; it compares only security- and behavior-relevant resolved fields and fails
// closed for constrained modes when effective behavior cannot be proven.

public enum OpenCodeEffectiveConfigUnsafeReason: Hashable, Sendable, CustomStringConvertible {
	case managedModeMissing(String)
	case prohibitedToolAllowed(mode: String, tool: String)
	case wildcardNotDenied(mode: String)
	case repoPromptMCPEntryMissing
	case repoPromptMCPEntryWrongCommand(expected: String, actual: String)
	case repoPromptMCPEntryWrongEnvironment(expected: String, actual: String)
	case repoPromptMCPEntryMalformedEnvironment(String)
	case repoPromptMCPEntryMalformedEnabled(String)
	case repoPromptMCPEntryWrongType(String)
	case malformedResolvedShape(String)
	case repoPromptMCPEntryNotDisabled
	case duplicateRepoPromptMCPAlias(String)
	case serverOverrideDetected(String)

	public var description: String {
		switch self {
		case .managedModeMissing(let mode): return "managed mode missing from resolved config: \(mode)"
		case .prohibitedToolAllowed(let mode, let tool): return "mode \(mode) leaves prohibited tool available: \(tool)"
		case .wildcardNotDenied(let mode): return "mode \(mode) is missing its wildcard deny"
		case .repoPromptMCPEntryMissing: return "expected RepoPrompt MCP entry is not effective"
		case .repoPromptMCPEntryWrongCommand(let expected, let actual): return "RepoPrompt MCP entry command mismatch (expected \(expected), effective \(actual))"
		case .repoPromptMCPEntryWrongEnvironment(let expected, let actual): return "RepoPrompt MCP entry environment mismatch (expected \(expected), effective \(actual))"
		case .repoPromptMCPEntryMalformedEnvironment(let detail): return "RepoPrompt MCP entry environment has an unusable shape: \(detail)"
		case .repoPromptMCPEntryMalformedEnabled(let detail): return "RepoPrompt MCP entry `enabled` has an unusable shape: \(detail)"
		case .repoPromptMCPEntryWrongType(let actual): return "RepoPrompt MCP entry has unexpected transport type: \(actual)"
		case .malformedResolvedShape(let detail): return "resolved configuration has an unusable shape: \(detail)"
		case .repoPromptMCPEntryNotDisabled: return "RepoPrompt MCP entry is effective but this launch requires it disabled"
		case .duplicateRepoPromptMCPAlias(let alias): return "duplicate RepoPrompt-like MCP alias in effective config: \(alias)"
		case .serverOverrideDetected(let detail): return "effective server override detected: \(detail)"
		}
	}
}

public enum OpenCodeEffectiveConfigVerdict: Hashable, Sendable {
	case safe(diagnostics: [String])
	case unsafe(reasons: [OpenCodeEffectiveConfigUnsafeReason])
}

/// The exact launch specification the effective RepoPrompt MCP entry must match.
///
/// Comparing only `command.first` (seventh round, finding 3) accepted
/// `[expectedCommand, "--exec", "…"]` as the expected bridge: same executable, entirely
/// different role. The environment was not compared at all. Verification is therefore
/// now EXACT over the whole argv array and over the environment.
///
/// Exactness policy for the environment: the effective entry's environment must equal
/// the expected map exactly — same keys, same values, no extras. RepoPrompt controls
/// every variable it puts on this entry, so an unexpected key is by definition not the
/// bridge RepoPrompt configured, and an inherited variable is exactly the kind of
/// behavior change this verdict exists to catch.
public struct ExpectedMCPLaunch: Hashable, Sendable {
	/// Complete argv, in order.
	public let command: [String]
	/// Complete expected environment for the entry.
	public let environment: [String: String]
	/// The transport type the entry must declare.
	public let type: String

	public init(command: [String], environment: [String: String], type: String = "local") {
		self.command = command
		self.environment = environment
		self.type = type
	}

	/// STRUCTURAL rendering for mismatch diagnostics — never raw argument values
	/// (ninth round, finding 5). A mismatched argv is by definition attacker- or
	/// third-party-controlled and can carry bearer tokens or API keys; this string
	/// reaches the run transcript and, at enforcing stages, a refusal message. Only the
	/// executable's basename, the argument count, and recognizable option NAMES are
	/// reported. Values after an option, and any non-option argument, are elided.
	static func describe(command: [String]) -> String {
		guard let executable = command.first else { return "(empty)" }
		let basename = executable.split(separator: "/").last.map(String.init) ?? executable
		let optionNames = command.dropFirst()
			.filter { $0.hasPrefix("-") }
			.map { $0.split(separator: "=").first.map(String.init) ?? $0 }
		let options = optionNames.isEmpty ? "" : " options=[\(optionNames.joined(separator: ","))]"
		return "exe=\(basename) argc=\(command.count)\(options)"
	}

	/// Renders an environment for a USER-VISIBLE diagnostic.
	///
	/// Keys and a digest of the values only (eighth-round audit). The seventh round
	/// rendered `KEY=VALUE` pairs, and this string flows into the run transcript: a
	/// measured `debug config --pure` on 1.18.4 returns every configured MCP server,
	/// including third-party entries whose environments hold API keys and bearer tokens.
	/// A mismatch diagnostic must never be the thing that prints them.
	static func describe(environment: [String: String]) -> String {
		guard !environment.isEmpty else { return "(empty)" }
		// Keys and a COUNT only. The eighth round rendered a stable digest of the
		// values; that is still evidence about secrets — it lets an observer confirm a
		// guess or match the same secret across records — so it is gone (ninth round,
		// finding 5).
		return "keys=[\(environment.keys.sorted().joined(separator: ","))] count=\(environment.count)"
	}
}

/// What one launch expects to be effective. Produced app-side from the launch plan.
public struct OpenCodeEffectiveConfigExpectation: Sendable {
	public let requiredModeID: String
	/// Tools that must NOT be allowed in the required mode (permission value must be "deny").
	public let prohibitedTools: [String]
	/// Whether the mode must carry a wildcard deny (`"*": "deny"`).
	public let requiresWildcardDeny: Bool
	/// Expected canonical RepoPrompt MCP server name.
	public let repoPromptMCPName: String
	/// When non-nil, the effective RepoPrompt MCP entry must launch EXACTLY this
	/// specification.
	public let expectedMCPLaunch: ExpectedMCPLaunch?
	/// When true, the RepoPrompt MCP entry must be disabled/ineffective in this launch.
	public let requiresMCPDisabled: Bool

	public init(
		requiredModeID: String,
		prohibitedTools: [String],
		requiresWildcardDeny: Bool,
		repoPromptMCPName: String,
		expectedMCPLaunch: ExpectedMCPLaunch?,
		requiresMCPDisabled: Bool
	) {
		self.requiredModeID = requiredModeID
		self.prohibitedTools = prohibitedTools
		self.requiresWildcardDeny = requiresWildcardDeny
		self.repoPromptMCPName = repoPromptMCPName
		self.expectedMCPLaunch = expectedMCPLaunch
		self.requiresMCPDisabled = requiresMCPDisabled
	}
}

public enum OpenCodeEffectiveConfigEvaluator {
	/// Evaluates a resolved-config JSON object against one launch expectation.
	///
	/// `resolvedConfig` is the parsed output of `opencode debug config --pure`. Missing or
	/// unparseable resolved state must be handled by the caller (fail closed for
	/// constrained modes); this function evaluates only present state.
	public static func evaluate(
		resolvedConfig: [String: Any],
		expectation: OpenCodeEffectiveConfigExpectation
	) -> OpenCodeEffectiveConfigVerdict {
		var reasons: [OpenCodeEffectiveConfigUnsafeReason] = []
		var diagnostics: [String] = []

		let agents = resolvedConfig["agent"] as? [String: Any] ?? [:]
		guard let mode = agents[expectation.requiredModeID] as? [String: Any] else {
			reasons.append(.managedModeMissing(expectation.requiredModeID))
			return .unsafe(reasons: reasons)
		}

		let permissions = normalizedPermissions(from: mode["permission"])
		for tool in expectation.prohibitedTools {
			let effective = permissions[tool] ?? permissions["*"]
			if effective != "deny" {
				reasons.append(.prohibitedToolAllowed(mode: expectation.requiredModeID, tool: tool))
			}
		}
		if expectation.requiresWildcardDeny, permissions["*"] != "deny" {
			reasons.append(.wildcardNotDenied(mode: expectation.requiredModeID))
		}

		// The mcp ROOT is shape-checked too (ninth round, finding 5): present-but-not-an
		// object silently became "no servers", which reads as "the expected entry is
		// missing" rather than "this config cannot be evaluated".
		var servers: [String: Any] = [:]
		if let raw = resolvedConfig["mcp"] {
			if let object = raw as? [String: Any] {
				servers = object
			} else if !(raw is NSNull) {
				reasons.append(.malformedResolvedShape("mcp root is \(type(of: raw)), not an object"))
			}
		}
		let repoPromptEntries = servers.filter { key, _ in
			normalizedAlias(key).contains(normalizedAlias(expectation.repoPromptMCPName))
				|| normalizedAlias(key) == normalizedAlias(expectation.repoPromptMCPName)
		}
		let exactEntry = servers.first { key, _ in
			key.compare(expectation.repoPromptMCPName, options: .caseInsensitive) == .orderedSame
		}

		if repoPromptEntries.count > 1 {
			for alias in repoPromptEntries.keys.sorted()
			where alias.compare(expectation.repoPromptMCPName, options: .caseInsensitive) != .orderedSame {
				reasons.append(.duplicateRepoPromptMCPAlias(alias))
			}
		}

		let entryObject = exactEntry?.value as? [String: Any]
		// `enabled` is TYPED (eighth round, finding 6): absent means the documented
		// default (an entry that exists is effective), but a non-Bool value is a shape
		// this app never writes and must not silently inherit the safe default.
		let enabledShape = Self.enabledShape(from: entryObject)
		let entryEnabled: Bool
		switch enabledShape {
		case .absent: entryEnabled = entryObject != nil
		case .valid(let value): entryEnabled = value
		case .malformed(let detail):
			entryEnabled = true
			reasons.append(.repoPromptMCPEntryMalformedEnabled(detail))
		}
		// A malformed command shape (missing, not an array, or containing non-strings)
		// is NOT "no command" — it is an entry whose argv cannot be established, which
		// can never be proven equal to the expectation.
		let entryCommand = entryObject?["command"] as? [String]

		if expectation.requiresMCPDisabled {
			if entryObject != nil, entryEnabled, entryCommand?.first != "/usr/bin/false" {
				reasons.append(.repoPromptMCPEntryNotDisabled)
			}
		} else if let expected = expectation.expectedMCPLaunch {
			if entryObject == nil || !entryEnabled {
				reasons.append(.repoPromptMCPEntryMissing)
			} else {
				// Exact argv: extra, missing, or reordered elements all fail, so a
				// same-executable entry with an added `--exec` can no longer pass.
				if entryCommand != expected.command {
					reasons.append(.repoPromptMCPEntryWrongCommand(
						expected: ExpectedMCPLaunch.describe(command: expected.command),
						actual: entryCommand.map { ExpectedMCPLaunch.describe(command: $0) } ?? "absent or malformed"
					))
				}
				// Absent, valid, and malformed are DISTINCT states (eighth round,
				// finding 6). Collapsing absence and malformation to `[:]` meant a
				// `"environment":"malformed"` entry compared equal to the production
				// expectation, which is an empty map — so an entry whose shape could not
				// be established evaluated SAFE.
				//
				// Absence is not accepted as equivalent to an explicit empty map:
				// measured against OpenCode 1.18.4, `debug config --pure` PRESERVES an
				// explicitly written `"environment": {}` and omits the key only when the
				// input omitted it. RepoPrompt's overlay always writes the key, so its
				// absence means something other than RepoPrompt wrote this entry.
				switch Self.environmentShape(from: entryObject?["environment"]) {
				case .malformed(let detail):
					reasons.append(.repoPromptMCPEntryMalformedEnvironment(detail))
				case .absent:
					reasons.append(.repoPromptMCPEntryWrongEnvironment(
						expected: ExpectedMCPLaunch.describe(environment: expected.environment),
						actual: "absent"
					))
				case .valid(let entryEnvironment):
					if entryEnvironment != expected.environment {
						reasons.append(.repoPromptMCPEntryWrongEnvironment(
							expected: ExpectedMCPLaunch.describe(environment: expected.environment),
							actual: ExpectedMCPLaunch.describe(environment: entryEnvironment)
						))
					}
				}
				let entryType = entryObject?["type"] as? String
				if entryType != expected.type {
					reasons.append(.repoPromptMCPEntryWrongType(entryType ?? "absent"))
				}
			}
		}

		// Effective server overrides can redirect the internal ACP HTTP listener. Explicit
		// CLI arguments take precedence, but surface the conflict as unsafe: an inherited
		// non-loopback intent must be visible, not silently overridden.
		// Server-override fields are shape-checked rather than pattern-matched: a
		// `hostname` that is not a string, or an `mdns`/`cors` of an unexpected type,
		// previously fell through every `as?` and left constrained safety UNPROVEN while
		// the verdict still said safe (ninth round, finding 5).
		if let rawServer = resolvedConfig["server"], !(rawServer is NSNull) {
			guard let server = rawServer as? [String: Any] else {
				reasons.append(.malformedResolvedShape("server root is \(type(of: rawServer)), not an object"))
				return finish(reasons: reasons, diagnostics: diagnostics)
			}
			if let rawHostname = server["hostname"], !(rawHostname is NSNull) {
				if let hostname = rawHostname as? String {
					if hostname != "127.0.0.1", hostname != "localhost" {
						reasons.append(.serverOverrideDetected("hostname=\(hostname)"))
					}
				} else {
					reasons.append(.malformedResolvedShape("server.hostname is \(type(of: rawHostname)), not a string"))
				}
			}
			if let rawMDNS = server["mdns"], !(rawMDNS is NSNull) {
				if let number = rawMDNS as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
					if number.boolValue { reasons.append(.serverOverrideDetected("mdns=true")) }
				} else {
					reasons.append(.malformedResolvedShape("server.mdns is \(type(of: rawMDNS)), not a boolean"))
				}
			}
			if let rawCORS = server["cors"], !(rawCORS is NSNull) {
				if let cors = rawCORS as? [Any] {
					if !cors.isEmpty { reasons.append(.serverOverrideDetected("cors origins configured")) }
				} else {
					reasons.append(.malformedResolvedShape("server.cors is \(type(of: rawCORS)), not an array"))
				}
			}
			diagnostics.append("server override keys: \(server.keys.sorted().joined(separator: ","))")
		}

		return finish(reasons: reasons, diagnostics: diagnostics)
	}

	private static func finish(
		reasons: [OpenCodeEffectiveConfigUnsafeReason],
		diagnostics: [String]
	) -> OpenCodeEffectiveConfigVerdict {
		reasons.isEmpty ? .safe(diagnostics: diagnostics) : .unsafe(reasons: reasons)
	}

	/// A typed shape, so absence and malformation cannot impersonate an empty map.
	enum ShapeResult<Value> {
		case absent
		case valid(Value)
		case malformed(String)
	}

	static func environmentShape(from value: Any?) -> ShapeResult<[String: String]> {
		guard let value else { return .absent }
		if value is NSNull { return .absent }
		guard let object = value as? [String: Any] else {
			return .malformed("expected an object, found \(type(of: value))")
		}
		var out: [String: String] = [:]
		for (key, raw) in object {
			guard let string = raw as? String, !(raw is NSNumber) else {
				return .malformed("value for key \(key) is \(type(of: raw)), not a string")
			}
			out[key] = string
		}
		return .valid(out)
	}

	static func enabledShape(from entry: [String: Any]?) -> ShapeResult<Bool> {
		guard let entry, let raw = entry["enabled"] else { return .absent }
		// An explicit null is a value the app never writes; treating it as absence let
		// it inherit the effective-by-default rule (ninth round, finding 5).
		if raw is NSNull { return .malformed("explicit null") }
		guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
			return .malformed("expected a boolean, found \(type(of: raw))")
		}
		return .valid(number.boolValue)
	}

	static func normalizedPermissions(from value: Any?) -> [String: String] {
		guard let object = value as? [String: Any] else { return [:] }
		var out: [String: String] = [:]
		for (key, raw) in object {
			if let string = raw as? String {
				out[key] = string
			} else if let nested = raw as? [String: Any] {
				// Pattern-object form (e.g. bash: {"*": "allow"}); use the wildcard entry.
				if let wildcard = nested["*"] as? String {
					out[key] = wildcard
				}
			}
		}
		return out
	}

	static func normalizedAlias(_ name: String) -> String {
		name.lowercased()
			.replacingOccurrences(of: "-", with: "")
			.replacingOccurrences(of: "_", with: "")
			.replacingOccurrences(of: " ", with: "")
	}
}

import Foundation

/// Pure validation of the secure OpenCode ACP launch contract.
///
/// Every embedded ACP launch/probe must constrain the HTTP server that `opencode acp`
/// starts internally: authenticated numeric loopback, OS-assigned port, mDNS off, no
/// added CORS origins, and `--pure`. This validator inspects a FINAL argv/environment
/// pair and reports violations; it never constructs argv itself (the app-side launch
/// plan owns construction, and re-validates its own output as defense in depth).
public enum OpenCodeSecureLaunchContract {
	public static let requiredHostname = "127.0.0.1"
	public static let requiredPortArgument = "0"
	public static let serverPasswordEnvironmentKey = "OPENCODE_SERVER_PASSWORD"
	/// Minimum accepted password length (characters). App-side generation produces far
	/// more entropy; this floor only guards against an accidentally empty/trivial value.
	public static let minimumServerPasswordLength = 32

	public enum Violation: Hashable, Sendable, CustomStringConvertible {
		case missingACPSubcommand
		case missingRequiredArgument(String)
		case duplicateArgument(String)
		case nonLoopbackHostname(String)
		case fixedPort(String)
		case mdnsEnabled
		case corsOriginSupplied
		case pureModeMissing
		case autoApprovalFlag(String)
		case unexpectedSecurityFlag(String)
		case missingServerPassword
		case weakServerPassword
		case serverPasswordInArguments

		public var description: String {
			switch self {
			case .missingACPSubcommand: return "argv does not start with the 'acp' subcommand"
			case .missingRequiredArgument(let name): return "required argument missing: \(name)"
			case .duplicateArgument(let name): return "duplicate argument: \(name)"
			case .nonLoopbackHostname(let value): return "hostname is not numeric loopback: \(value)"
			case .fixedPort(let value): return "port is not OS-assigned (0): \(value)"
			case .mdnsEnabled: return "mDNS is not disabled"
			case .corsOriginSupplied: return "CORS origin supplied"
			case .pureModeMissing: return "--pure missing"
			case .autoApprovalFlag(let name): return "auto-approval flag present: \(name)"
			case .unexpectedSecurityFlag(let name): return "security-weakening flag present: \(name)"
			case .missingServerPassword: return "OPENCODE_SERVER_PASSWORD missing or empty"
			case .weakServerPassword: return "OPENCODE_SERVER_PASSWORD is below the minimum entropy floor"
			case .serverPasswordInArguments: return "server password value appears in argv"
			}
		}
	}

	/// Flags that weaken security or change approval semantics and are never acceptable
	/// in an embedded managed launch, even if inherited from user configuration.
	static let forbiddenFlagPrefixes: [String] = [
		"--cors",
		"--mdns-domain",
		"--auto",
		"--share"
	]

	/// Validates the final argv (excluding the executable itself) and environment of an
	/// ACP launch. Returns all violations; an empty array means the contract holds.
	public static func validate(
		arguments: [String],
		environment: [String: String]
	) -> [Violation] {
		var violations: [Violation] = []

		guard arguments.first == "acp" else {
			return [.missingACPSubcommand]
		}

		let flags = parseFlags(Array(arguments.dropFirst()))

		for name in ["--hostname", "--port", "--mdns", "--pure"] {
			let count = flags.occurrences(of: name)
			if count == 0 {
				switch name {
				case "--pure":
					violations.append(.pureModeMissing)
				default:
					violations.append(.missingRequiredArgument(name))
				}
			} else if count > 1 {
				violations.append(.duplicateArgument(name))
			}
		}

		// The LAST occurrence wins in CLI semantics, so validate final effective values.
		if let hostname = flags.lastValue(of: "--hostname"), hostname != requiredHostname {
			violations.append(.nonLoopbackHostname(hostname))
		}
		if let port = flags.lastValue(of: "--port"), port != requiredPortArgument {
			violations.append(.fixedPort(port))
		}
		if let mdns = flags.lastValue(of: "--mdns"), mdns.lowercased() != "false" {
			violations.append(.mdnsEnabled)
		}

		for argument in arguments.dropFirst() {
			for prefix in forbiddenFlagPrefixes where argument == prefix || argument.hasPrefix(prefix + "=") {
				switch prefix {
				case "--cors":
					violations.append(.corsOriginSupplied)
				case "--auto":
					violations.append(.autoApprovalFlag(argument))
				default:
					violations.append(.unexpectedSecurityFlag(argument))
				}
			}
		}

		let password = environment[serverPasswordEnvironmentKey] ?? ""
		if password.isEmpty {
			violations.append(.missingServerPassword)
		} else if password.count < minimumServerPasswordLength {
			violations.append(.weakServerPassword)
		} else if arguments.contains(where: { $0.contains(password) }) {
			violations.append(.serverPasswordInArguments)
		}

		return violations
	}

	// MARK: - Flag parsing

	struct ParsedFlags {
		/// Ordered (name, value?) pairs as they appear on the command line.
		let entries: [(name: String, value: String?)]

		func occurrences(of name: String) -> Int {
			entries.filter { $0.name == name }.count
		}

		func lastValue(of name: String) -> String? {
			entries.last(where: { $0.name == name })?.value
		}
	}

	/// Parses `--flag value` and `--flag=value` forms into ordered entries. Boolean flags
	/// without a following value (or followed by another flag) get a nil value.
	static func parseFlags(_ arguments: [String]) -> ParsedFlags {
		var entries: [(name: String, value: String?)] = []
		var index = 0
		while index < arguments.count {
			let argument = arguments[index]
			if argument.hasPrefix("--") {
				if let equals = argument.firstIndex(of: "=") {
					let name = String(argument[..<equals])
					let value = String(argument[argument.index(after: equals)...])
					entries.append((name, value))
				} else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
					entries.append((argument, arguments[index + 1]))
					index += 1
				} else {
					entries.append((argument, nil))
				}
			}
			index += 1
		}
		return ParsedFlags(entries: entries)
	}
}

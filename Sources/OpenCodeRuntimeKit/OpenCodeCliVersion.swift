import Foundation

/// Strictly parsed OpenCode CLI semantic version (`major.minor.patch`).
///
/// OpenCode releases at a high cadence with plain semver tags (e.g. `1.18.4`). Anything
/// that does not match the exact three-component numeric form is rejected rather than
/// coerced; identity code must never guess at a version.
public struct OpenCodeCliVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
	public let major: Int
	public let minor: Int
	public let patch: Int

	public init?(string: String) {
		let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
		let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
		guard components.count == 3 else { return nil }
		var values: [Int] = []
		for component in components {
			guard !component.isEmpty,
				component.allSatisfy({ $0.isASCII && $0.isNumber }),
				component.count <= 6,
				let value = Int(component)
			else { return nil }
			// Reject zero-padded components ("01") so two spellings can never
			// alias the same version identity.
			if component.count > 1, component.first == "0" { return nil }
			values.append(value)
		}
		self.major = values[0]
		self.minor = values[1]
		self.patch = values[2]
	}

	public init(major: Int, minor: Int, patch: Int) {
		self.major = major
		self.minor = minor
		self.patch = patch
	}

	public var description: String { "\(major).\(minor).\(patch)" }

	public static func < (lhs: OpenCodeCliVersion, rhs: OpenCodeCliVersion) -> Bool {
		if lhs.major != rhs.major { return lhs.major < rhs.major }
		if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
		return lhs.patch < rhs.patch
	}
}

/// Closed inclusive version range used by the compatibility manifest.
public struct OpenCodeCliVersionRange: Hashable, Sendable {
	public let lowerBound: OpenCodeCliVersion
	public let upperBound: OpenCodeCliVersion

	public init?(lowerBound: OpenCodeCliVersion, upperBound: OpenCodeCliVersion) {
		guard lowerBound <= upperBound else { return nil }
		self.lowerBound = lowerBound
		self.upperBound = upperBound
	}

	public func contains(_ version: OpenCodeCliVersion) -> Bool {
		lowerBound <= version && version <= upperBound
	}
}

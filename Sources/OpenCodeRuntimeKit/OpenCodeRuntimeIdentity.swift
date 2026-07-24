import Foundation

// Pure runtime-identity value types. This file cannot reference CommandPathResolver or any
// other app type — the boundary is enforced by the package graph rather than by review.
// Filesystem/process resolution that PRODUCES these values lives app-side
// (OpenCodeRuntimeIdentityResolver); this file only defines what a validated identity IS.

/// Validated lowercase-hex SHA-256 digest.
public struct OpenCodeSHA256: Hashable, Sendable, CustomStringConvertible {
	public let value: String

	public init?(_ value: String) {
		guard value.count == 64,
			value.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
		else { return nil }
		self.value = value
	}

	public var description: String { value }
}

/// How the executable is signed. Codesign metadata is diagnostic identity evidence only —
/// the measured real-world OpenCode binary is ad-hoc/linker signed with no TeamIdentifier,
/// so signing can detect change but can never authenticate a publisher.
public enum OpenCodeExecutableSigningClass: String, Hashable, Sendable, CaseIterable {
	case appleDeveloperID
	case otherSigned
	case adHoc
	case unsigned
	case invalid
	case unreadable
}

/// Coarse installation-location classification, inferred from the canonical real path and
/// labeled as a hint (never authority).
public enum OpenCodeExecutablePathClass: String, Hashable, Sendable, CaseIterable {
	/// The official installer location `~/.opencode/bin`.
	case openCodeManagedBin
	case homebrew
	case npmGlobal
	case userLocal
	case system
	case unknown
}

/// CPU architecture classes RepoPrompt distinguishes for compatibility evidence.
public enum OpenCodeExecutableArchitecture: String, Hashable, Sendable, CaseIterable {
	case arm64
	case x86_64
	case universal
	case unknown
}

public enum OpenCodeRuntimeUnresolvableReason: String, Hashable, Sendable, CaseIterable {
	case noCommand
	case commandNotFound
	case notExecutable
	case isDirectory
	case canonicalPathUnreadable
	case hashUnreadable
	case versionProbeFailed
	case versionUnparsable
}

/// Canonical identity of one resolved OpenCode executable. Two binaries with the same
/// semantic version can differ by bytes, architecture, packaging, or local replacement;
/// compatibility observations must therefore key on this identity, never on `"opencode"`
/// or a bare version string.
public struct OpenCodeRuntimeIdentity: Hashable, Sendable {
	public let resolvedPath: String
	public let realPath: String
	public let sha256: OpenCodeSHA256
	public let sizeBytes: Int
	public let modificationEpochSeconds: Int?
	public let architecture: OpenCodeExecutableArchitecture
	public let signingClass: OpenCodeExecutableSigningClass
	public let pathClass: OpenCodeExecutablePathClass
	public let cliVersion: OpenCodeCliVersion

	public init?(
		resolvedPath: String,
		realPath: String,
		sha256: OpenCodeSHA256,
		sizeBytes: Int,
		modificationEpochSeconds: Int?,
		architecture: OpenCodeExecutableArchitecture,
		signingClass: OpenCodeExecutableSigningClass,
		pathClass: OpenCodeExecutablePathClass,
		cliVersion: OpenCodeCliVersion
	) {
		guard !resolvedPath.isEmpty, !realPath.isEmpty, sizeBytes > 0 else { return nil }
		self.resolvedPath = resolvedPath
		self.realPath = realPath
		self.sha256 = sha256
		self.sizeBytes = sizeBytes
		self.modificationEpochSeconds = modificationEpochSeconds
		self.architecture = architecture
		self.signingClass = signingClass
		self.pathClass = pathClass
		self.cliVersion = cliVersion
	}

	/// Classifies a canonical real path into a bounded installation hint.
	public static func pathClass(forRealPath realPath: String) -> OpenCodeExecutablePathClass {
		let lowered = realPath.lowercased()
		if lowered.contains("/.opencode/bin/") { return .openCodeManagedBin }
		if lowered.contains("/homebrew/") || lowered.contains("/usr/local/cellar/") { return .homebrew }
		if lowered.contains("/node_modules/") || lowered.contains("/lib/node/") || lowered.contains("/.npm") || lowered.contains("/npm/") { return .npmGlobal }
		if lowered.hasPrefix("/usr/local/") || lowered.contains("/.local/") { return .userLocal }
		if lowered.hasPrefix("/usr/") || lowered.hasPrefix("/bin/") || lowered.hasPrefix("/sbin/") { return .system }
		return .unknown
	}
}

public enum OpenCodeRuntimeResolution: Hashable, Sendable {
	case resolved(OpenCodeRuntimeIdentity)
	case unresolvable(OpenCodeRuntimeUnresolvableReason)
}

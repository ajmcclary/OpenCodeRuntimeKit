// swift-tools-version: 6.0
import PackageDescription

// OpenCodeRuntimeKit — OpenCode-specific, UI-free runtime foundations.
//
// Promoted verbatim out of RepoPrompt's internal RepoPromptCore package
// (its OpenCodeRuntimeCore target) as the eighth extraction of the
// migrate.md package map and the fourth — and final — provider-runtime
// promotion of staged-plan step 5. RepoPromptCore's OpenCodeRuntimeCore
// target is now an @_exported re-export shim over this package (the
// AgentRuntimeKit / PromptAssemblyKit / ApplyEditsKit / CodexRuntimeKit /
// CodexAppServerKit / ClaudeRuntimeKit promotion precedent).
//
// Scope — deterministic OpenCode runtime values and pure policy:
//   * CLI version, runtime identity, the typed launch-profile and
//     contract compatibility keys with their domain-separated canonical
//     encodings, and the closed compatibility manifest with its
//     fail-closed decoder;
//   * staged admission enforcement, the admission coordinator and its
//     prelaunch / post-initialize query and assessment values;
//   * capability snapshots and intersection, compatibility evaluation,
//     effective-configuration evaluation, and the observation values;
//   * secure launch-contract validation as a pure value-level contract
//     over an already-constructed launch shape;
//   * raw event envelopes, fragmented tool-input assembly, the JSON
//     number policy, and resumable incremental SHA-256;
//   * session-recovery values, runtime diagnostics, and usage snapshots
//     with their redaction and accounting rules.
//
// Deliberately OUT of scope — RepoPrompt keeps all of it:
// OpenCode process spawning and ownership, executable discovery,
// environment construction, working-directory policy, launch-plan
// CONSTRUCTION and the authorization decision it feeds, retry,
// cancellation, and termination; configuration-file mutation and the
// transactional persistent-config installers; rollout execution and
// enforcement-stage selection; filesystem I/O of every kind, including
// the compatibility-manifest RESOURCE and its loader (this package
// decodes values and never touches Bundle/FileManager), manifest and
// contract-lock GENERATION, and the evidence corpus; persistent
// observation-history storage, session-recovery persistence,
// authentication and account handling, workspace authority, MCP server
// policy, application recovery orchestration, projection into app chat
// models, view models, and all UI. This package is intentionally
// OpenCode-specific — it is not a multi-provider abstraction and not a
// replacement for the OpenCode SDK; provider-neutral agent vocabulary
// lives in AgentRuntimeKit alongside it.
//
// Zero package dependencies, and Foundation is the only import in any
// source file. The SHA-256 used by the compatibility keys and by the
// resumable incremental hasher is implemented here rather than taken
// from CryptoKit on purpose: CryptoKit's in-progress state is not
// serializable, and mid-stream persistence is a requirement of replay
// reconciliation. Swift 5 language mode keeps the moved code
// byte-behaviorally identical (the AgentRuntimeKit / PromptAssemblyKit /
// ApplyEditsKit / CodexRuntimeKit / ClaudeRuntimeKit / RepoPromptCore
// promoted-target precedent).
let package = Package(
    name: "OpenCodeRuntimeKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "OpenCodeRuntimeKit", targets: ["OpenCodeRuntimeKit"])
    ],
    targets: [
        .target(
            name: "OpenCodeRuntimeKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenCodeRuntimeKitTests",
            dependencies: ["OpenCodeRuntimeKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

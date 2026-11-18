# OpenCodeRuntimeKit

Deterministic runtime foundations for hosts that drive the OpenCode CLI over ACP.

OpenCodeRuntimeKit holds the parts of an OpenCode integration (`opencode acp`) that are
pure values and policy: parsing the CLI version, identifying a runtime and deciding
whether to admit it, checking that a launch is secure, evaluating resolved configuration
and `initialize` capabilities, accounting for every raw ACP frame, assembling fragmented
tool input, planning session recovery after process loss, and recording usage and
redacted diagnostics. It performs no filesystem or process I/O. Your host builds the
launch, runs `opencode`, and persists state. This package checks and interprets what the
host hands it.

## What's inside

- `OpenCodeCliVersion`, `OpenCodeCliVersionRange` — strict `major.minor.patch` parsing
  with no prerelease, padding, or coercion, plus closed inclusive ranges.
- `OpenCodeRuntimeIdentity`, `OpenCodeSHA256`, `OpenCodeRuntimeResolution` — a resolved
  runtime (binary digest, bounded signing/path/architecture classes) or a typed
  unresolvable reason.
- `OpenCodeLaunchProfileKey`, `OpenCodeContractKey` — two distinct typed compatibility
  keys, so the two axes cannot be swapped at a call site. Each hashes a
  length-prefixed, domain-separated canonical encoding of its `…KeyInput`, so no input
  value can forge a field boundary.
- `OpenCodeCompatibilityManifest` — the certified-runtime manifest. `decode(from:)` takes
  `Data` and fails closed on any shape outside the schema
  (`OpenCodeManifestDecodingError`); the manifest itself is supplied by the host.
- `OpenCodeAdmissionCoordinator`, `OpenCodeAdmissionEnforcementStage`,
  `OpenCodeAdmissionEnforcementResolution` — pre-launch and post-initialize admission
  with staged enforcement. The built-in `shippingStage` is `.observeOnly`, which records
  assessments but never blocks a launch. A malformed override resolves to observe-only.
- `OpenCodeObservationHistory` — a bounded admission history used only for diagnostics.
  It never grants a capability or permits a resume.
- `OpenCodeSecureLaunchContract` — *validates* a final `opencode acp` argv and
  environment: numeric loopback, OS-assigned port, mDNS off, no CORS or auto-approval
  flags, `--pure`, and a strong server password that does not appear in argv. It never
  builds argv.
- `OpenCodeCapabilitySnapshot`, `OpenCodeEffectiveSessionCapabilities` — decoded ACP
  `initialize` evidence. Unknown capability keys are kept so that drift is visible.
- `OpenCodeEffectiveConfigEvaluator` — compares resolved configuration (the output of
  `opencode debug config --pure`) against a launch expectation.
- `OpenCodeRawEventEnvelope`, `OpenCodeEnvelopeAccounting` — sequences and classifies
  every raw frame as normalized, suppressed with a reason, opaque-unknown, or invalid.
- `OpenCodePartialToolInputAssembler` — merges `tool_call`/`tool_call_update` fragments
  per session and call, finalizes each call once, and bounds memory.
- `OpenCodeJSONNumberPolicy` — the single rule for untrusted wire numbers. Anything that
  is not exact becomes `nil` (unknown) and is never truncated, clamped, or set to zero.
- `OpenCodeIncrementalSHA256` — resumable SHA-256 whose in-progress state is `Codable`.
- `OpenCodeSessionRecoveryRecord`, `OpenCodeTranscriptFrontier`,
  `OpenCodeSessionRecoveryPlanner` — plan at most one capability-gated resume after a
  process dies, deduplicate replay, and refuse explicitly rather than silently starting
  a new session.
- `OpenCodeSecretRedactor`, `OpenCodeRuntimeDiagnosticRecord`, `OpenCodeUsageSnapshot` —
  key- and pattern-based redaction, bounded diagnostic records, and nullable usage
  snapshots that keep their provenance.

## When to use it

- You launch `opencode acp` yourself and need deterministic, testable rules for
  versioning, admission, launch security, capability and config checks, frame
  accounting, recovery, and usage.
- You want those rules with no dependencies at all. Foundation is the only import.

## When not to use it

- **For an ACP client** (JSON-RPC, connection, sessions, permissions, turn execution),
  use [AgentExecutionKit](https://github.com/ajmcclary/AgentExecutionKit)'s `AgentACP*`
  products. Its `AgentACPRPC` and `AgentACPSession` build on this package. Its
  `AgentClaude*` products cover Claude.
- **For provider-neutral agent vocabulary**, use
  [AgentRuntimeKit](https://github.com/ajmcclary/AgentRuntimeKit). This package is
  OpenCode-specific. It is not a multi-provider abstraction and does not replace the
  OpenCode SDK.
- **For other providers:** use [ClaudeRuntimeKit](https://github.com/ajmcclary/ClaudeRuntimeKit)
  for Claude Code and [CodexRuntimeKit](https://github.com/ajmcclary/CodexRuntimeKit) for
  Codex.
- **Out of scope:** process spawning and termination, executable discovery, environment
  and working-directory policy, launch-plan *construction*, configuration-file changes,
  choosing an enforcement stage for rollout, loading or generating the manifest, any
  persistence (observation history, recovery records), authentication, MCP server policy,
  and UI.

## Installation

```swift
dependencies: [
    // 0.1.0-beta.5 is a prerelease identifier — SwiftPM only resolves
    // prerelease tags when the lower bound itself names one.
    .package(url: "https://github.com/ajmcclary/OpenCodeRuntimeKit.git", .upToNextMinor(from: "0.1.0-beta.5"))
]
```

```swift
.target(
    name: "MyTarget",
    dependencies: [.product(name: "OpenCodeRuntimeKit", package: "OpenCodeRuntimeKit")]
)
```

## Usage

```swift
import Foundation
import OpenCodeRuntimeKit

// Strict version parsing: exactly `major.minor.patch`, anything else is nil.
let version = OpenCodeCliVersion(string: "1.18.4")!
let certified = OpenCodeCliVersionRange(lowerBound: .init(major: 1, minor: 18, patch: 0),
                                        upperBound: .init(major: 1, minor: 18, patch: 9))!
print(certified.contains(version))                     // true

// Validate the FINAL argv/environment your launcher built before spawning `opencode acp`.
let password = String(repeating: "x", count: 48)       // generate a real secret in practice
let violations = OpenCodeSecureLaunchContract.validate(
    arguments: ["acp", "--hostname", "127.0.0.1", "--port", "8080", "--mdns=false", "--pure"],
    environment: [OpenCodeSecureLaunchContract.serverPasswordEnvironmentKey: password]
)
print(violations.map(\.description))                   // ["port is not OS-assigned (0): 8080"]

// Resumable SHA-256: persist the hasher mid-stream, resume later, same digest.
var hasher = OpenCodeIncrementalSHA256()
hasher.update(utf8: "Hello, ")
let checkpoint = try JSONEncoder().encode(hasher)      // store it wherever you persist state
var resumed = try JSONDecoder().decode(OpenCodeIncrementalSHA256.self, from: checkpoint)
resumed.update(utf8: "world")
print(resumed.finalizedHex())                          // SHA-256 of "Hello, world"

// Untrusted wire numbers become nil (unknown), never truncated, clamped, or zero.
print(OpenCodeJSONNumberPolicy.boundedUsageCount(NSNumber(value: 1.5)) as Any)  // nil
print(OpenCodeJSONNumberPolicy.boundedUsageCount(NSNumber(value: 42)) as Any)   // Optional(42)

// Redaction for support diagnostics.
print(OpenCodeSecretRedactor.redactValues(in: ["OPENCODE_SERVER_PASSWORD": password]))
// ["OPENCODE_SERVER_PASSWORD": "«redacted»"]
```

## Requirements

- Swift tools 6.0, Swift 6 language mode with complete concurrency checking. The package
  consists only of `Sendable` value types. It has no reference types and no
  `@unchecked Sendable`.
- macOS 27.0+ and iOS 27.0+. There are no process, filesystem, or AppKit dependencies,
  so both platforms build the whole package.
- Dependencies: none. Foundation is the only import. SHA-256 is implemented here instead
  of using CryptoKit because CryptoKit cannot serialize an in-progress hash, and replay
  reconciliation needs to persist one mid-stream.

## Stability

Pre-1.0 (`0.x` beta). The public API may change between minor versions, so pin with
`.upToNextMinor`.

## Development

`swift build` and `swift test`. The test suite is fast and fully in-memory.

## Origin

Extracted from the RepoPrompt app (Apache-2.0).

## License

Apache License 2.0 — see [LICENSE](LICENSE).

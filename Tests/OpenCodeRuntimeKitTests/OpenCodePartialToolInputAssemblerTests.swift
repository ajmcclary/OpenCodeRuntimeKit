import XCTest
@testable import OpenCodeRuntimeKit

final class OpenCodePartialToolInputAssemblerTests: XCTestCase {
	private let key = OpenCodePartialToolInputAssembler.Key(sessionID: "ses_1", toolCallID: "call_1")

	func testFragmentedInputAssemblesToExactlyOneFinalInput() {
		var assembler = OpenCodePartialToolInputAssembler()

		XCTAssertNil(assembler.ingest(
			key: key, toolName: "bash",
			rawInput: ["command": "ls"], textFragment: nil, status: "pending"
		))
		XCTAssertNil(assembler.ingest(
			key: key, toolName: nil,
			rawInput: ["cwd": "/tmp"], textFragment: "partial ", status: "in_progress"
		))
		let final = assembler.ingest(
			key: key, toolName: nil,
			rawInput: nil, textFragment: "output", status: "completed"
		)

		XCTAssertEqual(final?.terminalState, .completed)
		XCTAssertEqual(final?.toolName, "bash")
		XCTAssertEqual(final?.appendedText, "partial output")
		XCTAssertEqual(final?.updateCount, 3)
		XCTAssertEqual(final?.mergedInputJSON, #"{"command":"ls","cwd":"/tmp"}"#)
		XCTAssertEqual(assembler.metrics.finalized, 1)
		XCTAssertFalse(final?.isIncomplete ?? true)
	}

	func testConflictingSnapshotsRetainLatestAndCount() {
		var assembler = OpenCodePartialToolInputAssembler()
		_ = assembler.ingest(key: key, toolName: "edit", rawInput: ["path": "/a"], textFragment: nil, status: nil)
		_ = assembler.ingest(key: key, toolName: nil, rawInput: ["path": "/b"], textFragment: nil, status: nil)
		let final = assembler.ingest(key: key, toolName: nil, rawInput: nil, textFragment: nil, status: "completed")

		XCTAssertEqual(final?.conflictingSnapshotCount, 1)
		XCTAssertEqual(final?.mergedInputJSON, #"{"path":"/b"}"#, "latest snapshot wins deterministically")
		XCTAssertEqual(assembler.metrics.conflicts, 1)
	}

	func testDuplicateTerminalIsCountedNotMerged() {
		var assembler = OpenCodePartialToolInputAssembler()
		_ = assembler.ingest(key: key, toolName: "bash", rawInput: nil, textFragment: nil, status: "completed")
		let duplicate = assembler.ingest(key: key, toolName: "bash", rawInput: nil, textFragment: nil, status: "completed")
		XCTAssertNil(duplicate)
		XCTAssertEqual(assembler.metrics.duplicateTerminals, 1)
	}

	func testLateNonTerminalUpdateAfterFinalizeIsCounted() {
		var assembler = OpenCodePartialToolInputAssembler()
		_ = assembler.ingest(key: key, toolName: "bash", rawInput: nil, textFragment: nil, status: "completed")
		XCTAssertNil(assembler.ingest(key: key, toolName: nil, rawInput: ["x": 1], textFragment: nil, status: "in_progress"))
		XCTAssertEqual(assembler.metrics.lateUpdates, 1)
	}

	func testClassifiedIngestDistinguishesAccumulationTerminalDuplicateAndLate() {
		var assembler = OpenCodePartialToolInputAssembler()
		guard case .accumulated = assembler.ingestClassified(
			key: key, toolName: "bash", rawInput: ["command": "ls"], textFragment: nil, status: "in_progress"
		) else { return XCTFail("non-terminal ingest must classify as accumulated") }
		guard case .terminal(let assembled) = assembler.ingestClassified(
			key: key, toolName: nil, rawInput: ["cwd": "/tmp"], textFragment: nil, status: "completed"
		) else { return XCTFail("terminal status must classify as terminal") }
		XCTAssertEqual(assembled.mergedInputJSON, #"{"command":"ls","cwd":"/tmp"}"#)
		guard case .duplicateTerminal = assembler.ingestClassified(
			key: key, toolName: nil, rawInput: nil, textFragment: nil, status: "completed"
		) else { return XCTFail("second terminal must classify as duplicateTerminal") }
		guard case .lateUpdate = assembler.ingestClassified(
			key: key, toolName: nil, rawInput: nil, textFragment: nil, status: "in_progress"
		) else { return XCTFail("post-terminal non-terminal frame must classify as lateUpdate") }
		XCTAssertEqual(assembler.metrics.duplicateTerminals, 1)
		XCTAssertEqual(assembler.metrics.lateUpdates, 1)
	}

	func testCancelledStatusFinalizesAsCancelled() {
		var assembler = OpenCodePartialToolInputAssembler()
		let final = assembler.ingest(key: key, toolName: "bash", rawInput: nil, textFragment: nil, status: "cancelled")
		XCTAssertEqual(final?.terminalState, .cancelled)
	}

	func testExpireAllProducesExplicitIncompleteState() {
		var assembler = OpenCodePartialToolInputAssembler()
		_ = assembler.ingest(key: key, toolName: "bash", rawInput: ["command": "sleep"], textFragment: nil, status: "in_progress")
		let other = OpenCodePartialToolInputAssembler.Key(sessionID: "ses_1", toolCallID: "call_2")
		_ = assembler.ingest(key: other, toolName: "edit", rawInput: nil, textFragment: nil, status: nil)

		let expired = assembler.expireAll()
		XCTAssertEqual(expired.count, 2)
		XCTAssertTrue(expired.allSatisfy(\.isIncomplete))
		XCTAssertEqual(assembler.metrics.expired, 2)
		XCTAssertEqual(assembler.metrics.openCalls, 0)
	}

	func testExpireSessionOnlyTouchesThatSession() {
		var assembler = OpenCodePartialToolInputAssembler()
		let otherSession = OpenCodePartialToolInputAssembler.Key(sessionID: "ses_2", toolCallID: "call_9")
		_ = assembler.ingest(key: key, toolName: "bash", rawInput: nil, textFragment: nil, status: nil)
		_ = assembler.ingest(key: otherSession, toolName: "bash", rawInput: nil, textFragment: nil, status: nil)

		let expired = assembler.expireSession("ses_1")
		XCTAssertEqual(expired.map(\.key), [key])
		XCTAssertEqual(assembler.metrics.openCalls, 1)
	}

	func testMemoryBoundExpiresLeastRecentlyTouched() {
		var assembler = OpenCodePartialToolInputAssembler(maxOpenCalls: 2)
		let keys = (0..<3).map { OpenCodePartialToolInputAssembler.Key(sessionID: "ses_1", toolCallID: "call_\($0)") }
		for key in keys {
			_ = assembler.ingest(key: key, toolName: "bash", rawInput: nil, textFragment: nil, status: nil)
		}
		XCTAssertEqual(assembler.metrics.openCalls, 2)
		XCTAssertEqual(assembler.metrics.expired, 1)
	}

	func testCapacityEvictionSurfacesIncompleteCallExactlyOnce() {
		var assembler = OpenCodePartialToolInputAssembler(maxOpenCalls: 1)
		let first = OpenCodePartialToolInputAssembler.Key(sessionID: "ses_1", toolCallID: "call_0")
		let second = OpenCodePartialToolInputAssembler.Key(sessionID: "ses_1", toolCallID: "call_1")
		_ = assembler.ingest(key: first, toolName: "bash", rawInput: ["command": "ls"], textFragment: nil, status: nil)
		_ = assembler.ingest(key: second, toolName: "edit", rawInput: nil, textFragment: nil, status: nil)

		let evicted = assembler.drainEvictedCalls()
		XCTAssertEqual(evicted.map(\.key), [first], "the capacity bound must surface the evicted call, not discard it")
		XCTAssertEqual(evicted.first?.terminalState, .expired)
		XCTAssertEqual(evicted.first?.isIncomplete, true)
		XCTAssertEqual(evicted.first?.toolName, "bash")
		XCTAssertTrue(assembler.drainEvictedCalls().isEmpty, "an evicted call must be surfaced exactly once")
	}

	// MARK: - Sendable merged-input storage (Swift 6 migration)

	/// The assembler stores each ingested field as its canonical JSON encoding
	/// rather than as `Any`. For every value shape that survives a JSON
	/// round-trip — which is every shape reachable from a decoded wire payload
	/// except negative zero, pinned separately by
	/// `testNegativeZeroIsTheOneKnownRoundTripDivergence()` — the merged
	/// document is byte-identical to serializing the same object directly,
	/// including nesting and the `withoutEscapingSlashes` rule.
	func testMergedDocumentIsByteIdenticalToDirectSerialization() {
		let payload: [String: Any] = [
			"path": "/a/b.swift",
			"count": 3,
			"ratio": 0.5,
			"flag": true,
			"missing": NSNull(),
			"list": [1, "two", false],
			"nested": ["inner": ["deep": 1, "slash": "x/y"]]
		]
		var assembler = OpenCodePartialToolInputAssembler()
		let final = assembler.ingest(key: key, toolName: "edit", rawInput: payload, textFragment: nil, status: "completed")

		XCTAssertEqual(
			final?.mergedInputJSON,
			OpenCodePartialToolInputAssembler.serializeSorted(payload),
			"the sendable per-field encoding must round-trip to the same document as direct serialization"
		)
		XCTAssertEqual(
			final?.mergedInputJSON,
			#"{"count":3,"flag":true,"list":[1,"two",false],"missing":null,"nested":{"inner":{"deep":1,"slash":"x/y"}},"path":"/a/b.swift","ratio":0.5}"#
		)
	}

	/// Negative zero is the ONE value shape whose emitted bytes changed when the
	/// merged input became per-field `Data` (Swift 6 migration).
	///
	/// Before, the original `Any` was held until the end and serialized once, so
	/// a `Double` of `-0.0` reached `JSONSerialization` intact and emitted `-0`.
	/// Now each field is serialized at ingest and decoded again to rebuild the
	/// document — and `-0` carries no `.` or exponent, so JSON re-parses it as an
	/// *integer* zero, which re-emits as `0`.
	///
	/// This is pinned rather than fixed. Rebuilding the document by splicing the
	/// stored canonical bytes would preserve `-0`, but it would require
	/// replicating `JSONSerialization`'s `.sortedKeys` key collation, which is
	/// not plain byte order (it sorts `_x` < `😀` < `2` < `10`, `a` < `A`,
	/// `ss` < `ß`). Reimplementing that opaque ordering would risk reordering
	/// every multi-field document — a far larger wire change than the one it
	/// would fix. Delegating key order to Foundation, exactly as before, is the
	/// safer contract.
	///
	/// `-0` and `0` are numerically equal in JSON, and `mergedInputJSON` feeds no
	/// digest, contract lock, or persisted hash — it is only ever surfaced as a
	/// display/telemetry string.
	func testNegativeZeroIsTheOneKnownRoundTripDivergence() {
		var assembler = OpenCodePartialToolInputAssembler()
		let final = assembler.ingest(
			key: key, toolName: "edit",
			rawInput: ["offset": -0.0 as Double], textFragment: nil, status: "completed"
		)

		XCTAssertEqual(
			final?.mergedInputJSON, #"{"offset":0}"#,
			"negative zero normalizes to 0 through the per-field encoding"
		)
		XCTAssertEqual(
			OpenCodePartialToolInputAssembler.serializeSorted(["offset": -0.0 as Double]),
			#"{"offset":-0}"#,
			"direct serialization still emits -0 — this asymmetry is the documented divergence"
		)
	}

	/// A single non-JSON value makes the whole merged document unavailable — the
	/// caller gets nil, never a partial input that silently dropped a field.
	func testNonJSONValueYieldsNoMergedDocumentRatherThanDroppingTheField() {
		var assembler = OpenCodePartialToolInputAssembler()
		let final = assembler.ingest(
			key: key, toolName: "edit",
			rawInput: ["command": "ls", "when": Date()], textFragment: nil, status: "completed"
		)
		XCTAssertNotNil(final)
		XCTAssertNil(final?.mergedInputJSON, "an unrepresentable field must poison the document, not vanish from it")
	}

	/// Non-finite numbers are not JSON, and are handled by the same rule.
	func testNonFiniteNumberIsUnrepresentableRatherThanSerialized() {
		var assembler = OpenCodePartialToolInputAssembler()
		let final = assembler.ingest(
			key: key, toolName: "edit",
			rawInput: ["ratio": Double.infinity], textFragment: nil, status: "completed"
		)
		XCTAssertNil(final?.mergedInputJSON)
	}

	/// Two unrepresentable snapshots of the same field are NOT equivalent: the
	/// assembler cannot prove they carry the same value, so the conflict is
	/// counted rather than assumed away.
	func testSuccessiveUnrepresentableSnapshotsStillCountAsConflicts() {
		var assembler = OpenCodePartialToolInputAssembler()
		_ = assembler.ingest(key: key, toolName: "edit", rawInput: ["when": Date()], textFragment: nil, status: nil)
		_ = assembler.ingest(key: key, toolName: nil, rawInput: ["when": Date()], textFragment: nil, status: nil)
		let final = assembler.ingest(key: key, toolName: nil, rawInput: nil, textFragment: nil, status: "completed")

		XCTAssertEqual(final?.conflictingSnapshotCount, 1)
		XCTAssertEqual(assembler.metrics.conflicts, 1)
	}

	/// Re-ingesting a structurally identical snapshot is not a conflict, even when
	/// the value is a nested container whose key order differs on the wire.
	func testIdenticalNestedSnapshotIsNotAConflict() {
		var assembler = OpenCodePartialToolInputAssembler()
		_ = assembler.ingest(
			key: key, toolName: "edit",
			rawInput: ["opts": ["a": 1, "b": 2]], textFragment: nil, status: nil
		)
		_ = assembler.ingest(
			key: key, toolName: nil,
			rawInput: ["opts": ["b": 2, "a": 1]], textFragment: nil, status: nil
		)
		let final = assembler.ingest(key: key, toolName: nil, rawInput: nil, textFragment: nil, status: "completed")

		XCTAssertEqual(final?.conflictingSnapshotCount, 0)
		XCTAssertEqual(final?.mergedInputJSON, #"{"opts":{"a":1,"b":2}}"#)
	}

	/// The assembler is a genuinely `Sendable` value — its merged input no longer
	/// holds `Any`. This exercises the cross-concurrency path the conformance
	/// promises: a partially assembled value is handed to another isolation
	/// domain, which finalizes it and returns intact assembled calls.
	func testPartiallyAssembledValueCrossesAnIsolationBoundaryIntact() async {
		var assembler = OpenCodePartialToolInputAssembler()
		_ = assembler.ingest(
			key: key, toolName: "bash",
			rawInput: ["command": "ls", "cwd": "/tmp"], textFragment: "partial", status: "in_progress"
		)

		let finalized = await AssemblerHandoffActor().expireAll(assembler)

		XCTAssertEqual(finalized.map(\.key), [key])
		XCTAssertEqual(finalized.first?.toolName, "bash")
		XCTAssertEqual(finalized.first?.appendedText, "partial")
		XCTAssertEqual(finalized.first?.mergedInputJSON, #"{"command":"ls","cwd":"/tmp"}"#)
		XCTAssertEqual(finalized.first?.terminalState, .expired)
		XCTAssertEqual(
			assembler.metrics.openCalls, 1,
			"the sender keeps its own copy — the handoff is a value copy, not shared state"
		)
	}
}

/// A second isolation domain, used to prove the assembler's `Sendable`
/// conformance is real rather than asserted.
private actor AssemblerHandoffActor {
	func expireAll(
		_ assembler: OpenCodePartialToolInputAssembler
	) -> [OpenCodePartialToolInputAssembler.AssembledCall] {
		var local = assembler
		return local.expireAll()
	}
}

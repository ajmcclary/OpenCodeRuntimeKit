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
}

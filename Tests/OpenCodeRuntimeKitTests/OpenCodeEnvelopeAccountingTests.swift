import XCTest
@testable import OpenCodeRuntimeKit

final class OpenCodeEnvelopeAccountingTests: XCTestCase {
	private func makeEnvelope(
		sequence: UInt64,
		direction: OpenCodeEnvelopeDirection = .inbound,
		kind: OpenCodeEnvelopeKind = .notification,
		disposition: OpenCodeEnvelopeDisposition
	) -> OpenCodeRawEventEnvelope {
		OpenCodeRawEventEnvelope(
			sequence: sequence,
			direction: direction,
			kind: kind,
			method: "session/update",
			requestID: nil,
			sessionID: "ses_1",
			sessionUpdateType: "agent_message_chunk",
			payloadByteCount: 128,
			disposition: disposition
		)
	}

	func testFullyAccountedRun() {
		var accounting = OpenCodeEnvelopeAccounting()
		accounting.record(makeEnvelope(sequence: 1, disposition: .normalized(eventCount: 1)))
		accounting.record(makeEnvelope(sequence: 2, disposition: .suppressed(reason: .sessionLoadReplay)))
		accounting.record(makeEnvelope(sequence: 3, disposition: .opaqueUnknown))
		accounting.record(makeEnvelope(sequence: 4, direction: .outbound, kind: .request, disposition: .notApplicable))

		XCTAssertEqual(accounting.inboundTotal, 3)
		XCTAssertEqual(accounting.outboundTotal, 1)
		XCTAssertEqual(accounting.normalized, 1)
		XCTAssertEqual(accounting.suppressedTotal, 1)
		XCTAssertEqual(accounting.opaqueUnknown, 1)
		XCTAssertEqual(accounting.unreasonedDrops, 0)
		XCTAssertTrue(accounting.isFullyAccounted)
	}

	func testNormalizedEnvelopeYieldingZeroEventsIsUnreasonedDrop() {
		var accounting = OpenCodeEnvelopeAccounting()
		accounting.record(makeEnvelope(sequence: 1, disposition: .normalized(eventCount: 0)))
		XCTAssertEqual(accounting.unreasonedDrops, 1)
		XCTAssertFalse(accounting.isFullyAccounted)
	}

	func testSuppressionReasonsAreCountedPerReason() {
		var accounting = OpenCodeEnvelopeAccounting()
		accounting.record(makeEnvelope(sequence: 1, disposition: .suppressed(reason: .lowLevelToolNoise)))
		accounting.record(makeEnvelope(sequence: 2, disposition: .suppressed(reason: .lowLevelToolNoise)))
		accounting.record(makeEnvelope(sequence: 3, disposition: .suppressed(reason: .lateEventAfterTerminal)))
		XCTAssertEqual(accounting.suppressed[.lowLevelToolNoise], 2)
		XCTAssertEqual(accounting.suppressed[.lateEventAfterTerminal], 1)
		XCTAssertEqual(accounting.suppressedTotal, 3)
	}

	func testSequenceRegressionDetected() {
		var accounting = OpenCodeEnvelopeAccounting()
		accounting.record(makeEnvelope(sequence: 5, disposition: .normalized(eventCount: 1)))
		accounting.record(makeEnvelope(sequence: 4, disposition: .normalized(eventCount: 1)))
		XCTAssertEqual(accounting.sequenceRegressions, 1)
	}

	func testInvalidFramesCounted() {
		var accounting = OpenCodeEnvelopeAccounting()
		accounting.record(makeEnvelope(sequence: 1, kind: .invalid, disposition: .opaqueUnknown))
		XCTAssertEqual(accounting.invalid, 1)
	}
}

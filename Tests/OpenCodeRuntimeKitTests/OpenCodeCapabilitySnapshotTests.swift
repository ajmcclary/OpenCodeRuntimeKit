import XCTest
@testable import OpenCodeRuntimeKit

final class OpenCodeCapabilitySnapshotTests: XCTestCase {
	func testDecodesOpenCodeStyleInitializeResponse() {
		let response: [String: Any] = [
			"protocolVersion": 1,
			"agentInfo": ["name": "opencode", "version": "1.18.4"],
			"authMethods": [["id": "opencode-login", "name": "Log in with opencode"]],
			"agentCapabilities": [
				"loadSession": true,
				"promptCapabilities": ["image": true, "embeddedContext": true],
				"mcpCapabilities": ["http": true, "sse": true],
				"sessionCapabilities": [
					"list": [String: Any](),
					"resume": [String: Any](),
					"close": [String: Any](),
					"unstable_forkSession": true,
					"somethingNew": true
				]
			]
		]

		let snapshot = OpenCodeCapabilitySnapshot.decode(initializeResponse: response)
		XCTAssertEqual(snapshot.protocolVersion, 1)
		XCTAssertEqual(snapshot.agentInfo?.name, "opencode")
		XCTAssertEqual(snapshot.agentInfo?.version, "1.18.4")
		XCTAssertEqual(snapshot.authMethodIDs, ["opencode-login"])
		XCTAssertTrue(snapshot.sessionCapabilities.loadSession)
		XCTAssertTrue(snapshot.sessionCapabilities.listSessions)
		XCTAssertTrue(snapshot.sessionCapabilities.resumeSession)
		XCTAssertTrue(snapshot.sessionCapabilities.closeSession)
		XCTAssertTrue(snapshot.sessionCapabilities.unstableForkSession)
		XCTAssertEqual(snapshot.unknownCapabilityKeys, ["sessionCapabilities.somethingNew"])
	}

	func testDecodesMinimalResponseWithoutCapabilities() {
		let snapshot = OpenCodeCapabilitySnapshot.decode(initializeResponse: ["protocolVersion": 1])
		XCTAssertEqual(snapshot.protocolVersion, 1)
		XCTAssertNil(snapshot.agentInfo)
		XCTAssertEqual(snapshot.sessionCapabilities, .none)
		XCTAssertEqual(snapshot.unknownCapabilityKeys, [])
	}

	func testMissingProtocolVersionIsSentinel() {
		let snapshot = OpenCodeCapabilitySnapshot.decode(initializeResponse: [:])
		XCTAssertEqual(snapshot.protocolVersion, -1)
	}

	func testDigestIsDeterministicAndSensitive() {
		let a = OpenCodeCapabilitySnapshot.decode(initializeResponse: ["protocolVersion": 1])
		let b = OpenCodeCapabilitySnapshot.decode(initializeResponse: ["protocolVersion": 1])
		let c = OpenCodeCapabilitySnapshot.decode(initializeResponse: ["protocolVersion": 2])
		XCTAssertEqual(a.digest, b.digest)
		XCTAssertNotEqual(a.digest, c.digest)
	}

	func testEffectiveCapabilitiesAreStrictIntersection() {
		let appPolicy = OpenCodeCapabilitySnapshot.SessionCapabilities(
			loadSession: true, listSessions: true, resumeSession: true, closeSession: true, unstableForkSession: true
		)
		let certified = OpenCodeCapabilitySnapshot.SessionCapabilities(
			loadSession: true, listSessions: true, resumeSession: false, closeSession: true, unstableForkSession: true
		)
		let advertised = OpenCodeCapabilitySnapshot.SessionCapabilities(
			loadSession: true, listSessions: false, resumeSession: true, closeSession: true, unstableForkSession: true
		)

		let effective = OpenCodeEffectiveSessionCapabilities(
			appPolicy: appPolicy, certified: certified, advertised: advertised
		)
		XCTAssertTrue(effective.loadSession)
		XCTAssertFalse(effective.listSessions, "advertisement absence must narrow")
		XCTAssertFalse(effective.resumeSession, "certification absence must narrow")
		XCTAssertTrue(effective.closeSession)
	}

	func testBehavioralIntersectionCannotWidenAppPolicy() {
		let appPolicy = OpenCodeCapabilitySnapshot.SessionCapabilities(
			loadSession: true, listSessions: false, resumeSession: true, closeSession: false, unstableForkSession: false
		)
		let advertised = OpenCodeCapabilitySnapshot.SessionCapabilities(
			loadSession: true, listSessions: true, resumeSession: true, closeSession: true, unstableForkSession: true
		)
		let effective = OpenCodeEffectiveSessionCapabilities(appPolicy: appPolicy, advertised: advertised)
		XCTAssertTrue(effective.loadSession)
		XCTAssertFalse(effective.listSessions)
		XCTAssertTrue(effective.resumeSession)
		XCTAssertFalse(effective.closeSession)
	}
}

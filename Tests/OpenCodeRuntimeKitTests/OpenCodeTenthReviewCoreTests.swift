import XCTest
@testable import OpenCodeRuntimeKit

/// Tenth acceptance-remediation round (2026-07-23), core-package half:
/// - finding 4: unsigned Foundation numbers must not wrap into a plausible small Int;
/// - finding 7: malformed initialize CONTAINERS must stay distinguishable from absence.
///
/// Every fixture is built from `JSONSerialization`-parsed BYTES. Written as Swift
/// literals these defects are invisible: `18446744073709519014` is not expressible as a
/// Swift `Int`, and the whole point is what Foundation does with it.
final class OpenCodeTenthReviewCoreTests: XCTestCase {
	private func parsedObject(_ json: String) throws -> [String: Any] {
		try XCTUnwrap(
			JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
		)
	}

	// MARK: - Finding 4: unsigned representations

	/// The exact reported case. `int64Value` REINTERPRETS the unsigned representation,
	/// so this enormous positive number read back as `-32602` — the JSON-RPC
	/// invalid-params code, which the controller treats as a signal to abandon the
	/// session and create a new one.
	func testUnsignedIntegerAboveInt64MaxIsUnknownNotWrapped() throws {
		let object = try parsedObject("""
		{"a":18446744073709519014,"b":18446744073709519013,
		 "c":9223372036854775808,"d":18446744073709551615}
		""")
		for key in ["a", "b", "c", "d"] {
			XCTAssertNil(
				OpenCodeJSONNumberPolicy.exactInteger(object[key]),
				"\(key) exceeds Int and must be unknown, never a wrapped value"
			)
			XCTAssertNil(OpenCodeJSONNumberPolicy.nonNegativeCount(object[key]))
		}
	}

	/// The specific impersonations named in the finding: the wrapped readings are
	/// exactly the two codes the fallback path keys on.
	func testWrappedUnsignedValuesCannotImpersonateJSONRPCErrorCodes() throws {
		let object = try parsedObject("""
		{"invalidParams":18446744073709519014,"internalError":18446744073709519013}
		""")
		// Proof the wrap is real in this Foundation, so the assertions below are not
		// asserting the absence of something that never happened.
		let invalidParams = try XCTUnwrap(object["invalidParams"] as? NSNumber)
		XCTAssertEqual(invalidParams.int64Value, -32602, "the unsigned wrap must still be reproducible")
		let internalError = try XCTUnwrap(object["internalError"] as? NSNumber)
		XCTAssertEqual(internalError.int64Value, -32603)

		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(object["invalidParams"]))
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(object["internalError"]))
	}

	/// The policy did not simply become "reject large things": every value that IS
	/// exactly representable still converts, including the signed extremes.
	func testRepresentableIntegersStillConvertExactly() throws {
		let object = try parsedObject("""
		{"zero":0,"small":123,"negative":-32602,
		 "int64Max":9223372036854775807,"int64Min":-9223372036854775808}
		""")
		XCTAssertEqual(OpenCodeJSONNumberPolicy.exactInteger(object["zero"]), 0)
		XCTAssertEqual(OpenCodeJSONNumberPolicy.exactInteger(object["small"]), 123)
		XCTAssertEqual(OpenCodeJSONNumberPolicy.exactInteger(object["negative"]), -32602)
		XCTAssertEqual(OpenCodeJSONNumberPolicy.exactInteger(object["int64Max"]), Int.max)
		XCTAssertEqual(OpenCodeJSONNumberPolicy.exactInteger(object["int64Min"]), Int.min)
	}

	/// The earlier rounds' guarantees are unchanged by the new decoding route.
	func testEarlierNumberPolicyGuaranteesAreUnchanged() throws {
		let object = try parsedObject("""
		{"boolean":true,"float":1e300,"fraction":1.5,"safeFloat":2048.0,
		 "beyondSafeInteger":9007199254740993,"beyondSafeFloat":9007199254740993.0,
		 "stringCanonical":"42","stringPadded":" 42",
		 "stringPlus":"+42","stringLeadingZero":"042"}
		""")
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(object["boolean"]), "a JSON boolean is never a number")
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(object["float"]))
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(object["fraction"]))
		XCTAssertEqual(OpenCodeJSONNumberPolicy.exactInteger(object["safeFloat"]), 2048)
		// The 2^53-1 bound belongs to the FLOAT-backed branch, where an adjacent integer
		// may already have rounded onto the value. An integer-backed value is exact at any
		// magnitude Int can hold, and that is unchanged by the unsigned fix.
		XCTAssertEqual(OpenCodeJSONNumberPolicy.exactInteger(object["beyondSafeInteger"]), 9_007_199_254_740_993)
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(object["beyondSafeFloat"]), "a float beyond 2^53-1 may already have rounded on")
		XCTAssertEqual(OpenCodeJSONNumberPolicy.exactInteger(object["stringCanonical"]), 42)
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(object["stringPadded"]))
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(object["stringPlus"]))
		XCTAssertNil(OpenCodeJSONNumberPolicy.exactInteger(object["stringLeadingZero"]))
	}

	/// A protocol version is decoded through the same policy, so the wrap cannot
	/// manufacture one either.
	func testUnsignedProtocolVersionFailsClosed() throws {
		let response = try parsedObject(#"{"protocolVersion":18446744073709519014}"#)
		let snapshot = OpenCodeCapabilitySnapshot.decode(initializeResponse: response)
		XCTAssertEqual(snapshot.protocolVersion, -1)
		XCTAssertTrue(snapshot.unknownCapabilityKeys.contains("malformed:protocolVersion"))
	}

	// MARK: - Finding 7: malformed containers stay visible

	/// `agentCapabilities: []` previously became `[:]` — byte-identical evidence to a
	/// runtime that advertised no capabilities object at all.
	func testMalformedAgentCapabilitiesContainerIsRecordedNotErased() throws {
		for malformed in ["[]", "0", #""yes""#, "true"] {
			let response = try parsedObject("""
			{"protocolVersion":1,"agentCapabilities":\(malformed)}
			""")
			let snapshot = OpenCodeCapabilitySnapshot.decode(initializeResponse: response)
			XCTAssertTrue(
				snapshot.unknownCapabilityKeys.contains("malformed:agentCapabilities"),
				"\(malformed) must remain visible as malformed evidence"
			)
			XCTAssertFalse(snapshot.sessionCapabilities.loadSession, "malformed evidence never grants")
			XCTAssertFalse(snapshot.sessionCapabilities.resumeSession)
		}
	}

	func testMalformedSessionCapabilitiesContainerIsRecordedNotErased() throws {
		let response = try parsedObject("""
		{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":["resume"]}}
		""")
		let snapshot = OpenCodeCapabilitySnapshot.decode(initializeResponse: response)
		XCTAssertTrue(snapshot.unknownCapabilityKeys.contains("malformed:sessionCapabilities"))
		XCTAssertFalse(snapshot.sessionCapabilities.resumeSession)
	}

	/// Absence and explicit null stay ABSENT: they are not malformed, and inventing a
	/// malformed marker for them would make the evidence lie in the other direction.
	func testAbsentAndNullContainersAreNotMalformed() throws {
		for json in [#"{"protocolVersion":1}"#, #"{"protocolVersion":1,"agentCapabilities":null}"#] {
			let snapshot = OpenCodeCapabilitySnapshot.decode(initializeResponse: try parsedObject(json))
			XCTAssertFalse(
				snapshot.unknownCapabilityKeys.contains { $0.hasPrefix("malformed:agentCapabilities") },
				"absence is not malformed evidence"
			)
		}
	}

	func testMalformedAgentInfoAndAuthMethodsAreRecorded() throws {
		let response = try parsedObject("""
		{"protocolVersion":1,"agentInfo":"OpenCode","authMethods":{"id":"oauth"}}
		""")
		let snapshot = OpenCodeCapabilitySnapshot.decode(initializeResponse: response)
		XCTAssertNil(snapshot.agentInfo, "a string is not an agentInfo object")
		XCTAssertTrue(snapshot.unknownCapabilityKeys.contains("malformed:agentInfo"))
		XCTAssertTrue(snapshot.unknownCapabilityKeys.contains("malformed:authMethods"))
		XCTAssertTrue(snapshot.authMethodIDs.isEmpty)
	}

	func testMalformedAuthMethodEntriesAreRecordedWhileValidOnesSurvive() throws {
		let response = try parsedObject("""
		{"protocolVersion":1,"authMethods":[{"id":"oauth"},7,{"name":"no-id"}]}
		""")
		let snapshot = OpenCodeCapabilitySnapshot.decode(initializeResponse: response)
		XCTAssertEqual(snapshot.authMethodIDs, ["oauth"])
		XCTAssertEqual(
			snapshot.unknownCapabilityKeys.filter { $0 == "malformed:authMethods.entry" }.count,
			1,
			"repeated malformed entries collapse to one stable digest key"
		)
	}

	/// The documented shapes are untouched by the container hardening.
	func testDocumentedInitializeShapeStillDecodesUnchanged() throws {
		let response = try parsedObject("""
		{"protocolVersion":1,
		 "agentInfo":{"name":"OpenCode","version":"1.18.4"},
		 "authMethods":[{"id":"oauth"}],
		 "agentCapabilities":{"loadSession":true,"sessionCapabilities":{"resume":{},"list":true}}}
		""")
		let snapshot = OpenCodeCapabilitySnapshot.decode(initializeResponse: response)
		XCTAssertEqual(snapshot.protocolVersion, 1)
		XCTAssertEqual(snapshot.agentInfo?.name, "OpenCode")
		XCTAssertEqual(snapshot.agentInfo?.version, "1.18.4")
		XCTAssertEqual(snapshot.authMethodIDs, ["oauth"])
		XCTAssertTrue(snapshot.sessionCapabilities.loadSession)
		XCTAssertTrue(snapshot.sessionCapabilities.resumeSession)
		XCTAssertTrue(snapshot.sessionCapabilities.listSessions)
		XCTAssertFalse(snapshot.unknownCapabilityKeys.contains { $0.hasPrefix("malformed:") })
	}
}

import XCTest
@testable import OpenCodeRuntimeKit

final class OpenCodeSecureLaunchContractTests: XCTestCase {
	private let strongPassword = String(repeating: "p", count: 43)

	private var compliantArguments: [String] {
		["acp", "--hostname", "127.0.0.1", "--port", "0", "--mdns=false", "--pure"]
	}

	private var compliantEnvironment: [String: String] {
		[OpenCodeSecureLaunchContract.serverPasswordEnvironmentKey: strongPassword]
	}

	func testCompliantLaunchHasNoViolations() {
		XCTAssertEqual(
			OpenCodeSecureLaunchContract.validate(
				arguments: compliantArguments,
				environment: compliantEnvironment
			),
			[]
		)
	}

	func testMissingACPSubcommandIsFatal() {
		XCTAssertEqual(
			OpenCodeSecureLaunchContract.validate(arguments: ["serve"], environment: compliantEnvironment),
			[.missingACPSubcommand]
		)
	}

	func testMissingSecureArgumentsAreReportedIndividually() {
		let violations = OpenCodeSecureLaunchContract.validate(
			arguments: ["acp"],
			environment: compliantEnvironment
		)
		XCTAssertTrue(violations.contains(.missingRequiredArgument("--hostname")))
		XCTAssertTrue(violations.contains(.missingRequiredArgument("--port")))
		XCTAssertTrue(violations.contains(.missingRequiredArgument("--mdns")))
		XCTAssertTrue(violations.contains(.pureModeMissing))
	}

	func testNonLoopbackHostnameRejected() {
		var arguments = compliantArguments
		arguments[2] = "0.0.0.0"
		XCTAssertTrue(
			OpenCodeSecureLaunchContract.validate(arguments: arguments, environment: compliantEnvironment)
				.contains(.nonLoopbackHostname("0.0.0.0"))
		)
	}

	func testLocalhostNameIsNotAcceptedAsNumericLoopback() {
		var arguments = compliantArguments
		arguments[2] = "localhost"
		XCTAssertTrue(
			OpenCodeSecureLaunchContract.validate(arguments: arguments, environment: compliantEnvironment)
				.contains(.nonLoopbackHostname("localhost"))
		)
	}

	func testFixedPortRejected() {
		var arguments = compliantArguments
		arguments[4] = "4096"
		XCTAssertTrue(
			OpenCodeSecureLaunchContract.validate(arguments: arguments, environment: compliantEnvironment)
				.contains(.fixedPort("4096"))
		)
	}

	func testMdnsEnabledRejected() {
		var arguments = compliantArguments
		arguments[5] = "--mdns=true"
		XCTAssertTrue(
			OpenCodeSecureLaunchContract.validate(arguments: arguments, environment: compliantEnvironment)
				.contains(.mdnsEnabled)
		)
	}

	func testDuplicateWeakeningFinalArgumentRejected() {
		// A second --hostname that would win as the FINAL effective value.
		let arguments = compliantArguments + ["--hostname", "0.0.0.0"]
		let violations = OpenCodeSecureLaunchContract.validate(arguments: arguments, environment: compliantEnvironment)
		XCTAssertTrue(violations.contains(.duplicateArgument("--hostname")))
		XCTAssertTrue(violations.contains(.nonLoopbackHostname("0.0.0.0")), "last-wins effective value must be validated")
	}

	func testDuplicateCompliantArgumentStillRejected() {
		let arguments = compliantArguments + ["--hostname", "127.0.0.1"]
		XCTAssertTrue(
			OpenCodeSecureLaunchContract.validate(arguments: arguments, environment: compliantEnvironment)
				.contains(.duplicateArgument("--hostname"))
		)
	}

	func testCorsAndAutoAndShareFlagsRejected() {
		let violations = OpenCodeSecureLaunchContract.validate(
			arguments: compliantArguments + ["--cors=https://example.com", "--auto", "--share"],
			environment: compliantEnvironment
		)
		XCTAssertTrue(violations.contains(.corsOriginSupplied))
		XCTAssertTrue(violations.contains(.autoApprovalFlag("--auto")))
		XCTAssertTrue(violations.contains(.unexpectedSecurityFlag("--share")))
	}

	func testMissingAndWeakServerPassword() {
		XCTAssertTrue(
			OpenCodeSecureLaunchContract.validate(arguments: compliantArguments, environment: [:])
				.contains(.missingServerPassword)
		)
		XCTAssertTrue(
			OpenCodeSecureLaunchContract.validate(
				arguments: compliantArguments,
				environment: [OpenCodeSecureLaunchContract.serverPasswordEnvironmentKey: "short"]
			)
			.contains(.weakServerPassword)
		)
	}

	func testServerPasswordMayNeverAppearInArgv() {
		let violations = OpenCodeSecureLaunchContract.validate(
			arguments: compliantArguments + ["--password", strongPassword],
			environment: compliantEnvironment
		)
		XCTAssertTrue(violations.contains(.serverPasswordInArguments))
	}
}

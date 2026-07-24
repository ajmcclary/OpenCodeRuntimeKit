import XCTest
@testable import OpenCodeRuntimeKit

final class OpenCodeCompatibilityKeyTests: XCTestCase {
	private func makeLaunchInput(
		toolProfile: OpenCodeToolProfileClass = .agentMode,
		pure: Bool = true,
		digest: OpenCodeConfigDigest? = nil
	) -> OpenCodeLaunchProfileKeyInput {
		OpenCodeLaunchProfileKeyInput(
			transport: .acpStdio,
			listenerSecurity: .authenticatedLoopback,
			toolProfile: toolProfile,
			overlay: .managedWithActiveMCP,
			workingDirectoryClass: .workspaceRoot,
			pureMode: pure,
			overlayConfigDigest: digest
		)
	}

	func testLaunchProfileKeyIsDeterministic() {
		let a = OpenCodeLaunchProfileKey(input: makeLaunchInput())
		let b = OpenCodeLaunchProfileKey(input: makeLaunchInput())
		XCTAssertEqual(a, b)
	}

	func testLaunchProfileKeyChangesWithEveryAxis() {
		let base = OpenCodeLaunchProfileKey(input: makeLaunchInput())
		XCTAssertNotEqual(base, OpenCodeLaunchProfileKey(input: makeLaunchInput(toolProfile: .noTools)))
		XCTAssertNotEqual(base, OpenCodeLaunchProfileKey(input: makeLaunchInput(pure: false)))
		let digest = OpenCodeConfigDigest(sha256: OpenCodeSHA256Digest.digest(ofUTF8: "overlay"))
		XCTAssertNotEqual(base, OpenCodeLaunchProfileKey(input: makeLaunchInput(digest: digest)))
	}

	func testLaunchAndContractKeysAreDomainSeparated() {
		// Same nominal field content in both domains must never produce equal digests.
		let snapshotDigest = OpenCodeSHA256Digest.digest(ofUTF8: "content")
		let launch = OpenCodeLaunchProfileKey(input: makeLaunchInput())
		let contract = OpenCodeContractKey(input: OpenCodeContractKeyInput(
			acpProtocolVersion: 1,
			agentName: "opencode",
			capabilitySnapshotDigest: snapshotDigest,
			usedSurfaceLockHash: nil
		))
		XCTAssertNotEqual(launch.digest, contract.digest)
	}

	func testSHA256DigestMatchesKnownVector() {
		// FIPS 180-4 test vector: SHA-256("abc")
		XCTAssertEqual(
			OpenCodeSHA256Digest.digest(ofUTF8: "abc").value,
			"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
		)
		// SHA-256("")
		XCTAssertEqual(
			OpenCodeSHA256Digest.digest(of: Data()).value,
			"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
		)
	}

	func testLongInputDigestMatchesKnownVector() {
		// SHA-256 of 1,000,000 'a' characters (FIPS 180-4 long-message vector).
		let million = String(repeating: "a", count: 1_000_000)
		XCTAssertEqual(
			OpenCodeSHA256Digest.digest(ofUTF8: million).value,
			"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
		)
	}
}

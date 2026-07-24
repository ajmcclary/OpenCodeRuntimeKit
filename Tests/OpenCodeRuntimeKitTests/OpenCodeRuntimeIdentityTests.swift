import XCTest
@testable import OpenCodeRuntimeKit

final class OpenCodeRuntimeIdentityTests: XCTestCase {
	private let validSHA = OpenCodeSHA256("9449af91f517eacc2b0742fa93ae0da64fa6e5db7b714e30c62edea2a8de3f98")!

	func testSHA256AcceptsOnlyLowercaseHex64() {
		XCTAssertNotNil(OpenCodeSHA256(String(repeating: "a0", count: 32)))
		XCTAssertNil(OpenCodeSHA256(String(repeating: "A0", count: 32)), "uppercase must be rejected, not normalized")
		XCTAssertNil(OpenCodeSHA256("abc"))
		XCTAssertNil(OpenCodeSHA256(String(repeating: "g0", count: 32)))
	}

	func testIdentityRejectsEmptyPathsAndNonPositiveSize() {
		XCTAssertNil(OpenCodeRuntimeIdentity(
			resolvedPath: "",
			realPath: "/x",
			sha256: validSHA,
			sizeBytes: 1,
			modificationEpochSeconds: nil,
			architecture: .arm64,
			signingClass: .adHoc,
			pathClass: .openCodeManagedBin,
			cliVersion: OpenCodeCliVersion(string: "1.18.4")!
		))
		XCTAssertNil(OpenCodeRuntimeIdentity(
			resolvedPath: "/x",
			realPath: "/x",
			sha256: validSHA,
			sizeBytes: 0,
			modificationEpochSeconds: nil,
			architecture: .arm64,
			signingClass: .adHoc,
			pathClass: .openCodeManagedBin,
			cliVersion: OpenCodeCliVersion(string: "1.18.4")!
		))
	}

	func testPathClassification() {
		XCTAssertEqual(OpenCodeRuntimeIdentity.pathClass(forRealPath: "/Users/dev/.opencode/bin/opencode"), .openCodeManagedBin)
		XCTAssertEqual(OpenCodeRuntimeIdentity.pathClass(forRealPath: "/opt/homebrew/bin/opencode"), .homebrew)
		XCTAssertEqual(OpenCodeRuntimeIdentity.pathClass(forRealPath: "/usr/local/lib/node_modules/opencode-ai/bin/opencode"), .npmGlobal)
		XCTAssertEqual(OpenCodeRuntimeIdentity.pathClass(forRealPath: "/usr/local/bin/opencode"), .userLocal)
		XCTAssertEqual(OpenCodeRuntimeIdentity.pathClass(forRealPath: "/usr/bin/opencode"), .system)
		XCTAssertEqual(OpenCodeRuntimeIdentity.pathClass(forRealPath: "/Volumes/Somewhere/opencode"), .unknown)
	}
}

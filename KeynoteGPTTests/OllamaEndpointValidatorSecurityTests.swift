import XCTest
@testable import KeynoteGPT

final class OllamaEndpointValidatorSecurityTests: XCTestCase {
    func testAllowsLocalhostVariants() throws {
        XCTAssertEqual(try OllamaEndpointValidator.validatedBaseURL("http://127.0.0.1:11434"), "http://127.0.0.1:11434")
        XCTAssertEqual(try OllamaEndpointValidator.validatedBaseURL("http://localhost:11434/"), "http://localhost:11434")
        XCTAssertEqual(try OllamaEndpointValidator.validatedBaseURL("http://[::1]:11434"), "http://[::1]:11434")
    }

    func testAllowsPrivateLAN() throws {
        XCTAssertEqual(try OllamaEndpointValidator.validatedBaseURL("http://192.168.1.10:11434"), "http://192.168.1.10:11434")
        XCTAssertEqual(try OllamaEndpointValidator.validatedBaseURL("http://10.0.0.5:11434"), "http://10.0.0.5:11434")
        XCTAssertEqual(try OllamaEndpointValidator.validatedBaseURL("http://172.16.5.1:11434"), "http://172.16.5.1:11434")
    }

    func testRejectsFileAndCustomSchemes() {
        XCTAssertThrowsError(try OllamaEndpointValidator.validatedBaseURL("file:///etc/passwd")) { error in
            XCTAssertEqual(error as? OllamaEndpointValidator.ValidationError, .disallowedScheme("file"))
        }
        XCTAssertThrowsError(try OllamaEndpointValidator.validatedBaseURL("ftp://127.0.0.1/ollama"))
    }

    func testRejectsPublicInternetHosts() {
        XCTAssertThrowsError(try OllamaEndpointValidator.validatedBaseURL("https://example.com/api")) { error in
            guard let validation = error as? OllamaEndpointValidator.ValidationError,
                  case .disallowedHost = validation else {
                return XCTFail("expected disallowedHost, got \(error)")
            }
        }
        XCTAssertThrowsError(try OllamaEndpointValidator.validatedBaseURL("http://8.8.8.8:11434"))
    }

    func testStripsPathQueryAndUserInfo() throws {
        let url = try OllamaEndpointValidator.validatedBaseURL("http://user:pass@127.0.0.1:11434/secret?x=1#frag")
        XCTAssertEqual(url, "http://127.0.0.1:11434")
        XCTAssertFalse(url.contains("user"))
        XCTAssertFalse(url.contains("secret"))
    }

    func testRejectsEmpty() {
        XCTAssertThrowsError(try OllamaEndpointValidator.validatedBaseURL("   ")) { error in
            XCTAssertEqual(error as? OllamaEndpointValidator.ValidationError, .empty)
        }
    }

    func testAllowsDotLocalHosts() throws {
        XCTAssertEqual(
            try OllamaEndpointValidator.validatedBaseURL("http://mac-studio.local:11434"),
            "http://mac-studio.local:11434"
        )
    }
}

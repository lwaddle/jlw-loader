import XCTest
@testable import JLWLoader

final class APIClientTests: XCTestCase {

    // MARK: - Auth response decoding

    func testDecodeAuthResponse() throws {
        let json = """
        { "apiKey": "key_abc123", "orgId": "jlw-aviation" }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AuthResponse.self, from: json)
        XCTAssertEqual(response.apiKey, "key_abc123")
        XCTAssertEqual(response.orgId, "jlw-aviation")
    }

    func testDecodeAuthResponseWithOrgName() throws {
        let json = """
        { "apiKey": "key_abc123", "orgId": "jlw-aviation", "orgName": "JLW Aviation" }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AuthResponse.self, from: json)
        XCTAssertEqual(response.apiKey, "key_abc123")
        XCTAssertEqual(response.orgId, "jlw-aviation")
        XCTAssertEqual(response.orgName, "JLW Aviation")
    }

    func testDecodeAuthResponseWithoutOrgName() throws {
        let json = """
        { "apiKey": "key_abc123", "orgId": "jlw-aviation" }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AuthResponse.self, from: json)
        XCTAssertEqual(response.orgName, "jlw-aviation")
    }

    // MARK: - Download response decoding

    func testDecodeDownloadResponse() throws {
        let json = """
        { "downloadUrl": "https://r2.example.com/file.zip", "filename": "update.zip", "expiresIn": 900 }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(DownloadResponse.self, from: json)
        XCTAssertEqual(response.downloadUrl, "https://r2.example.com/file.zip")
        XCTAssertEqual(response.filename, "update.zip")
    }

    // MARK: - API error decoding

    func testDecodeAPIError() throws {
        let json = """
        { "error": "Access code not recognized. Contact your administrator." }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(APIErrorResponse.self, from: json)
        XCTAssertEqual(response.error, "Access code not recognized. Contact your administrator.")
    }
}

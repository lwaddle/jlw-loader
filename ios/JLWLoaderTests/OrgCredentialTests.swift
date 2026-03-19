import XCTest
@testable import JLWLoader

final class OrgCredentialTests: XCTestCase {

    func testEncodeDecode() throws {
        let cred = OrgCredential(orgId: "jlw-aviation", orgName: "JLW Aviation", apiKey: "key_abc123")
        let data = try JSONEncoder().encode(cred)
        let decoded = try JSONDecoder().decode(OrgCredential.self, from: data)
        XCTAssertEqual(decoded.orgId, "jlw-aviation")
        XCTAssertEqual(decoded.orgName, "JLW Aviation")
        XCTAssertEqual(decoded.apiKey, "key_abc123")
    }

    func testDecodeWithoutOrgName() throws {
        let json = """
        { "orgId": "jlw-aviation", "apiKey": "key_abc123" }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OrgCredential.self, from: json)
        XCTAssertEqual(decoded.orgId, "jlw-aviation")
        XCTAssertEqual(decoded.orgName, "jlw-aviation")
        XCTAssertEqual(decoded.apiKey, "key_abc123")
    }
}

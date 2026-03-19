import Foundation

struct OrgCredential: Codable, Identifiable, Equatable {
    let orgId: String
    let orgName: String
    let apiKey: String

    var id: String { orgId }

    init(orgId: String, orgName: String, apiKey: String) {
        self.orgId = orgId
        self.orgName = orgName
        self.apiKey = apiKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        orgId = try container.decode(String.self, forKey: .orgId)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        orgName = try container.decodeIfPresent(String.self, forKey: .orgName) ?? orgId
    }
}

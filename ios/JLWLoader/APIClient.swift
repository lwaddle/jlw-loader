import Foundation

// MARK: - Response types

struct AuthResponse: Codable {
    let apiKey: String
    let orgId: String
    let orgName: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        orgId = try container.decode(String.self, forKey: .orgId)
        orgName = try container.decodeIfPresent(String.self, forKey: .orgName) ?? orgId
    }
}

struct DownloadResponse: Codable {
    let downloadUrl: String
    let filename: String
    let expiresIn: Int
}

struct APIErrorResponse: Codable {
    let error: String
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case serverError(String)
    case networkError(Error)
    case decodingError
    case unauthorized
    case noCredentials

    var isUnauthorized: Bool {
        switch self {
        case .unauthorized, .noCredentials: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL."
        case .serverError(let message):
            return message
        case .networkError(let error):
            return error.localizedDescription
        case .decodingError:
            return "Unexpected response from server."
        case .unauthorized:
            return "Access code not recognized. Contact your administrator."
        case .noCredentials:
            return "No credentials found. Please re-enter your access code."
        }
    }
}

// MARK: - APIClient

struct APIClient {
    private let baseURL: String
    private let session: URLSession

    init(baseURL: String = Constants.apiBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Exchange access code for API key.
    /// POST /api/auth  { "accessCode": "JLW-7294" }
    func authenticate(accessCode: String) async throws -> AuthResponse {
        let body = ["accessCode": accessCode]
        return try await post("/api/auth", body: body, auth: .none)
    }

    /// Fetch current manifest for the authenticated org.
    func fetchManifest(apiKey: String) async throws -> Manifest {
        return try await get("/api/manifest", auth: .apiKey(apiKey))
    }

    /// Get presigned download URL.
    func getDownloadURL(apiKey: String) async throws -> DownloadResponse {
        let body: [String: String] = [:]
        return try await post("/api/download", body: body, auth: .apiKey(apiKey))
    }

    // MARK: - Private

    private enum Auth {
        case none
        case apiKey(String)
    }

    private func get<T: Decodable>(_ path: String, auth: Auth) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(auth, to: &request)

        return try await execute(request)
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable, auth: Auth) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        applyAuth(auth, to: &request)

        return try await execute(request)
    }

    private func applyAuth(_ auth: Auth, to request: inout URLRequest) {
        switch auth {
        case .none:
            break
        case .apiKey(let key):
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.decodingError
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw APIError.serverError(errorResp.error)
            }
            throw APIError.serverError("Request failed (HTTP \(httpResponse.statusCode))")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError
        }
    }
}

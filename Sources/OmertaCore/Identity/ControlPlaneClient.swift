import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SSO provider for authentication
public enum SSOProvider: String, Codable, Sendable {
    case apple
    case google
    case github
}

/// Authenticated session with control plane
public struct AuthSession: Codable, Sendable {
    public let token: String
    public let provider: SSOProvider
    public let account: String  // email
    public let expiresAt: Date

    public init(token: String, provider: SSOProvider, account: String, expiresAt: Date) {
        self.token = token
        self.provider = provider
        self.account = account
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        Date() > expiresAt
    }
}

/// Control plane client for cloud backup/sync and device transfer
public actor ControlPlaneClient {
    private let baseURL: URL
    private let urlSession: URLSession

    public init(baseURL: URL = URL(string: "https://api.omerta.io")!) {
        self.baseURL = baseURL
        self.urlSession = URLSession.shared
    }

    // MARK: - Authentication

    /// Authenticate with SSO provider
    /// Returns URL to open in browser for OAuth flow
    public func startAuthentication(_ provider: SSOProvider) async throws -> URL {
        let endpoint = baseURL.appendingPathComponent("auth/\(provider.rawValue)/start")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let (data, response) = try await urlSession.data(for: request)
        try validateResponse(response)

        let result = try JSONDecoder().decode(AuthStartResponse.self, from: data)
        return result.authURL
    }

    /// Complete authentication after OAuth callback
    public func completeAuthentication(code: String, provider: SSOProvider) async throws -> AuthSession {
        let endpoint = baseURL.appendingPathComponent("auth/\(provider.rawValue)/callback")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code])

        let (data, response) = try await urlSession.data(for: request)
        try validateResponse(response)

        return try JSONDecoder().decode(AuthSession.self, from: data)
    }

    // MARK: - Identity Backup

    /// Check if identity exists for this account
    public func hasIdentity(session: AuthSession) async throws -> Bool {
        let endpoint = baseURL.appendingPathComponent("identity/exists")

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        try validateResponse(response)

        let result = try JSONDecoder().decode(ExistsResponse.self, from: data)
        return result.exists
    }

    /// Upload encrypted identity for backup/sync
    public func uploadIdentity(_ encrypted: Data, session: AuthSession) async throws {
        let endpoint = baseURL.appendingPathComponent("identity/backup")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = encrypted

        let (_, response) = try await urlSession.data(for: request)
        try validateResponse(response)
    }

    /// Download encrypted identity
    public func downloadIdentity(session: AuthSession) async throws -> Data? {
        let endpoint = baseURL.appendingPathComponent("identity/backup")

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
            return nil
        }

        try validateResponse(response)
        return data
    }

    /// Delete identity backup
    public func deleteIdentity(session: AuthSession) async throws {
        let endpoint = baseURL.appendingPathComponent("identity/backup")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await urlSession.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Device Transfer

    /// Create transfer session (new device calls this)
    public func createTransferSession(
        publicKey: Data,
        session: AuthSession
    ) async throws -> TransferSession {
        let endpoint = baseURL.appendingPathComponent("transfer/create")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = CreateTransferRequest(publicKey: publicKey.base64EncodedString())
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        try validateResponse(response)

        return try JSONDecoder().decode(TransferSession.self, from: data)
    }

    /// Get transfer session by code (existing device calls this)
    public func getTransferSession(code: String) async throws -> TransferSession {
        let endpoint = baseURL.appendingPathComponent("transfer/\(code)")

        var request = URLRequest(url: endpoint)

        let (data, response) = try await urlSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
            throw IdentityError.transferNotFound
        }

        try validateResponse(response)
        return try JSONDecoder().decode(TransferSession.self, from: data)
    }

    /// Get pending transfer request (existing device polls this)
    public func getPendingTransfer(session: AuthSession) async throws -> TransferSession? {
        let endpoint = baseURL.appendingPathComponent("transfer/pending")

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
            return nil
        }

        try validateResponse(response)
        return try JSONDecoder().decode(TransferSession.self, from: data)
    }

    /// Complete transfer (existing device uploads encrypted identity)
    public func completeTransfer(
        sessionId: String,
        encryptedIdentity: EncryptedTransfer
    ) async throws {
        let endpoint = baseURL.appendingPathComponent("transfer/\(sessionId)/complete")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(encryptedIdentity)

        let (_, response) = try await urlSession.data(for: request)
        try validateResponse(response)
    }

    /// Get transfer result (new device polls this)
    public func getTransferResult(sessionId: String) async throws -> EncryptedTransfer? {
        let endpoint = baseURL.appendingPathComponent("transfer/\(sessionId)/result")

        var request = URLRequest(url: endpoint)

        let (data, response) = try await urlSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 404 || httpResponse.statusCode == 202 {
                return nil  // Not ready yet
            }
        }

        try validateResponse(response)
        return try JSONDecoder().decode(EncryptedTransfer.self, from: data)
    }

    /// Deny a transfer request
    public func denyTransfer(sessionId: String) async throws {
        let endpoint = baseURL.appendingPathComponent("transfer/\(sessionId)/deny")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let (_, response) = try await urlSession.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Private

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ControlPlaneError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ControlPlaneError.httpError(httpResponse.statusCode)
        }
    }
}

// MARK: - Request/Response Types

private struct AuthStartResponse: Codable {
    let authURL: URL
}

private struct ExistsResponse: Codable {
    let exists: Bool
}

private struct CreateTransferRequest: Codable {
    let publicKey: String
}

// MARK: - Errors

public enum ControlPlaneError: Error, Sendable {
    case invalidResponse
    case httpError(Int)
    case authenticationFailed
    case networkError(String)
}

extension ControlPlaneError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from control plane"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .authenticationFailed:
            return "Authentication failed"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

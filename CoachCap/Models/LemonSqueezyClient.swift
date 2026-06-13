import Foundation

// MARK: - Response models

struct LSLicenseKey: Codable {
    let id: Int?
    let status: String?      // "active", "expired", "disabled", "inactive"
    let activationLimit: Int?
    let activationUsage: Int?

    enum CodingKeys: String, CodingKey {
        case id, status
        case activationLimit = "activation_limit"
        case activationUsage = "activation_usage"
    }
}

struct LSInstance: Codable {
    let id: String?
    let name: String?
}

struct LSMeta: Codable {
    let storeId: Int?
    let variantId: Int?

    enum CodingKeys: String, CodingKey {
        case storeId   = "store_id"
        case variantId = "variant_id"
    }
}

/// Unified shape covering activate / validate / deactivate responses.
struct LSResponse: Codable {
    let activated: Bool?
    let valid: Bool?
    let deactivated: Bool?
    let error: String?
    let licenseKey: LSLicenseKey?
    let instance: LSInstance?
    let meta: LSMeta?

    enum CodingKeys: String, CodingKey {
        case activated, valid, deactivated, error, instance, meta
        case licenseKey = "license_key"
    }
}

// MARK: - Errors

enum LemonSqueezyError: LocalizedError {
    case offline(String)        // network unreachable / timeout — triggers grace
    case activationLimit        // key already active on another Mac
    case wrongProduct           // valid key, but for a different LS product
    case server(String)         // API-provided error message
    case malformed              // unparseable response

    var errorDescription: String? {
        switch self {
        case .offline(let m):    return m
        case .activationLimit:   return "This key is already active on another Mac — deactivate it there first."
        case .wrongProduct:      return "This license key isn't valid for CoachCam."
        case .server(let m):     return m
        case .malformed:         return "Unexpected response from the license server."
        }
    }

    /// True when the failure is a connectivity problem (not a definitive
    /// server "no"), so the caller can fall back to the offline grace window.
    var isConnectivity: Bool {
        if case .offline = self { return true }
        return false
    }
}

// MARK: - Client

actor LemonSqueezyClient {
    static let shared = LemonSqueezyClient()

    private let base = URL(string: "https://api.lemonsqueezy.com")!
    private let expectedStoreID   = 406047
    private let expectedVariantID = 1784319

    // MARK: Public calls

    /// Activate a key for this Mac. `instance_name` is the hardware UUID.
    func activate(key: String, instanceName: String, timeout: TimeInterval = 15) async throws -> LSResponse {
        let resp = try await post(
            path: "/v1/licenses/activate",
            fields: ["license_key": key, "instance_name": instanceName],
            timeout: timeout
        )
        if resp.activated != true {
            throw mapError(resp)
        }
        return resp
    }

    /// Validate an existing activation. Caller decides unlock based on
    /// `valid == true && license_key.status == "active"`.
    func validate(key: String, instanceID: String, timeout: TimeInterval = 8) async throws -> LSResponse {
        try await post(
            path: "/v1/licenses/validate",
            fields: ["license_key": key, "instance_id": instanceID],
            timeout: timeout
        )
    }

    /// Free this Mac's activation slot.
    func deactivate(key: String, instanceID: String, timeout: TimeInterval = 15) async throws -> LSResponse {
        let resp = try await post(
            path: "/v1/licenses/deactivate",
            fields: ["license_key": key, "instance_id": instanceID],
            timeout: timeout
        )
        if resp.deactivated != true {
            throw mapError(resp)
        }
        return resp
    }

    // MARK: Transport

    private func post(path: String, fields: [String: String], timeout: TimeInterval) async throws -> LSResponse {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = encodeForm(fields)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            // No connectivity / timeout / DNS — let the caller apply grace.
            throw LemonSqueezyError.offline(error.localizedDescription)
        }

        guard let parsed = try? JSONDecoder().decode(LSResponse.self, from: data) else {
            throw LemonSqueezyError.malformed
        }

        // Ownership check: whenever the server returns product metadata, it
        // must be CoachCam's store + variant, or a key from another LS product
        // could unlock the app.
        if let meta = parsed.meta {
            guard meta.storeId == expectedStoreID, meta.variantId == expectedVariantID else {
                throw LemonSqueezyError.wrongProduct
            }
        }
        return parsed
    }

    /// Translate a non-success response into a typed error.
    private func mapError(_ resp: LSResponse) -> LemonSqueezyError {
        if let msg = resp.error {
            if msg.lowercased().contains("activation limit") {
                return .activationLimit
            }
            return .server(msg)
        }
        return .malformed
    }

    private func encodeForm(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        return fields
            .map { "\(enc($0.key))=\(enc($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}

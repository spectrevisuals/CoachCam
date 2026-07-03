import Foundation

// MARK: - Response models
//
// Polar's customer-portal license-key API. Field names mirror the JSON exactly
// (snake_case mapped via CodingKeys). All three endpoints are unauthenticated —
// scoped by `organization_id` in the body — so nothing secret ships in the app,
// the same trust model as the old Lemon Squeezy client.

/// The license-key object. Returned nested inside an activation, and (with the
/// same fields) at the top level of a validate response.
struct PolarLicenseKey: Codable {
    let id: String?
    let benefitId: String?
    let status: String?          // "granted" (paid/active), "revoked", "disabled"
    let limitActivations: Int?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case benefitId        = "benefit_id"
        case limitActivations = "limit_activations"
        case expiresAt        = "expires_at"
    }
}

/// `POST /activate` response. `id` is the *activation instance* id — the analog
/// of Lemon Squeezy's `instance.id`, stored in the Keychain and passed to every
/// later validate/deactivate call.
struct PolarActivation: Codable {
    let id: String?
    let licenseKeyId: String?
    let licenseKey: PolarLicenseKey?

    enum CodingKeys: String, CodingKey {
        case id
        case licenseKeyId = "license_key_id"
        case licenseKey   = "license_key"
    }
}

/// `POST /validate` response. The license-key fields sit at the top level here
/// (not nested), so this is a flat mirror of `PolarLicenseKey`.
struct PolarValidation: Codable {
    let benefitId: String?
    let status: String?
    let limitActivations: Int?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case status
        case benefitId        = "benefit_id"
        case limitActivations = "limit_activations"
        case expiresAt        = "expires_at"
    }
}

/// Polar error envelope: `{"detail": "..."}` (string) or, for request-validation
/// failures, `{"detail": [ {msg, ...}, ... ]}`. We only need the human message.
private struct PolarErrorBody: Codable {
    let detail: PolarDetail?
    let error: String?
}

private enum PolarDetail: Codable {
    case message(String)
    case items([PolarDetailItem])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .message(s); return }
        if let a = try? c.decode([PolarDetailItem].self) { self = .items(a); return }
        self = .message("")
    }
    func encode(to encoder: Encoder) throws {}   // decode-only

    var text: String {
        switch self {
        case .message(let s): return s
        case .items(let a):   return a.compactMap { $0.msg }.joined(separator: "; ")
        }
    }
}

private struct PolarDetailItem: Codable { let msg: String? }

// MARK: - Errors

enum PolarError: LocalizedError {
    case offline(String)        // network unreachable / timeout — triggers grace
    case activationLimit        // key already activated on the max number of Macs
    case wrongProduct           // valid key, but not for CoachCam's benefit/org
    case notActive              // key exists but is revoked/disabled/not found
    case server(String)         // API-provided error message
    case malformed              // unparseable response

    var errorDescription: String? {
        switch self {
        case .offline(let m):    return m
        case .activationLimit:   return "This key is already active on another Mac — deactivate it there first."
        case .wrongProduct:      return "This license key isn't valid for CoachCam."
        case .notActive:         return "This license key is no longer active."
        case .server(let m):     return m
        case .malformed:         return "Unexpected response from the license server."
        }
    }

    /// True only for connectivity failures (not a definitive server "no"), so the
    /// caller can ride the offline grace window instead of revoking.
    var isConnectivity: Bool {
        if case .offline = self { return true }
        return false
    }
}

// MARK: - Client

actor PolarClient {
    static let shared = PolarClient()

    private let base = URL(string: "https://api.polar.sh")!

    // ─────────────────────────────────────────────────────────────────────────
    // TODO(confirm): these two IDs came from the Polar dashboard. `organization_id`
    // is required in every request; `benefit_id` is verified on every response so a
    // key from another product in the same org can't unlock CoachCam. If activation
    // fails with "wrong product" against a known-good key, these two are swapped.
    private let organizationID    = "03810e41-21d5-49f3-9795-df0efa3df428"
    private let expectedBenefitID = "12ddbb9a-a500-4dce-a673-e18c61c29079"
    // ─────────────────────────────────────────────────────────────────────────

    // MARK: Public calls

    /// Activate a key on this Mac. `label` is a human-readable machine name shown
    /// in the customer's Polar portal (so they can pick which to deactivate).
    /// One-per-Mac is enforced by the benefit's activation limit, not the label.
    func activate(key: String, label: String, timeout: TimeInterval = 15) async throws -> PolarActivation {
        let data = try await post(
            path: "/v1/customer-portal/license-keys/activate",
            body: ["key": key, "organization_id": organizationID, "label": label],
            timeout: timeout
        )
        guard let resp = try? JSONDecoder().decode(PolarActivation.self, from: data) else {
            throw PolarError.malformed
        }
        // Ownership: the activated key must belong to CoachCam's License Key benefit.
        if let benefit = resp.licenseKey?.benefitId, benefit != expectedBenefitID {
            throw PolarError.wrongProduct
        }
        return resp
    }

    /// Validate an existing activation. Caller unlocks on `status == "granted"`.
    /// Passing `activation_id` scopes the check to this Mac's activation.
    func validate(key: String, activationID: String, timeout: TimeInterval = 8) async throws -> PolarValidation {
        let data = try await post(
            path: "/v1/customer-portal/license-keys/validate",
            body: ["key": key, "organization_id": organizationID, "activation_id": activationID],
            timeout: timeout
        )
        guard let resp = try? JSONDecoder().decode(PolarValidation.self, from: data) else {
            throw PolarError.malformed
        }
        if let benefit = resp.benefitId, benefit != expectedBenefitID {
            throw PolarError.wrongProduct
        }
        return resp
    }

    /// Free this Mac's activation slot.
    func deactivate(key: String, activationID: String, timeout: TimeInterval = 15) async throws {
        _ = try await post(
            path: "/v1/customer-portal/license-keys/deactivate",
            body: ["key": key, "organization_id": organizationID, "activation_id": activationID],
            timeout: timeout
        )
    }

    // MARK: Transport

    /// POST a JSON body and return the raw response data, translating transport
    /// failures into `.offline` (→ grace) and non-2xx statuses into typed errors.
    private func post(path: String, body: [String: String], timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            data = d
            guard let h = resp as? HTTPURLResponse else { throw PolarError.malformed }
            http = h
        } catch let e as PolarError {
            throw e
        } catch {
            // No connectivity / timeout / DNS — let the caller apply grace.
            throw PolarError.offline(error.localizedDescription)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, data: data)
        }
        return data
    }

    /// Translate a non-2xx response into a typed error.
    private func mapError(status: Int, data: Data) -> PolarError {
        let message = (try? JSONDecoder().decode(PolarErrorBody.self, from: data))
            .flatMap { $0.detail?.text.isEmpty == false ? $0.detail?.text : $0.error }
            ?? ""
        let lower = message.lowercased()

        if lower.contains("activation") && (lower.contains("limit") || lower.contains("reached")) {
            return .activationLimit
        }
        // 404 = key not found for this org; 403 = revoked/disabled → definitive "no".
        if status == 404 || status == 403 {
            return message.isEmpty ? .notActive : .server(message)
        }
        return message.isEmpty ? .malformed : .server(message)
    }
}

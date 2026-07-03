import Foundation

/// Manages CoachCam's Polar subscription license.
///
/// Unlock model:
/// - A key is activated once per Mac, consuming the benefit's single activation
///   slot. Activating on a second Mac is refused until one is deactivated. The
///   Keychain stores the returned *activation id* (`instance`), passed to every
///   later validate/deactivate call.
/// - `validate` runs on launch. A `granted` status refreshes the grace clock;
///   a `revoked`/`disabled`/not-found status revokes immediately and overrides grace.
/// - When the server is unreachable we trust the last successful validation for
///   up to 30 days (full paid functionality), so offline coaches are never
///   dropped to the trial just for lacking a connection.
///
/// This is a timestamp-trust model, not cryptographically signed. The validation
/// step is isolated (`PolarClient`) so a signed-token provider could replace it
/// later without changing the UI surface.
@MainActor
final class LicenseManager: ObservableObject {

    /// The ONE shared licence state for the whole app. Every free-tier gate (recording
    /// length cap, monthly recording count, watermark) reads `LicenseManager.shared.isUnlocked`
    /// — a single source so paid/free can never drift between the three limits.
    static let shared = LicenseManager()

    // UI-facing surface — `isUnlocked == true` means PAID (valid Polar licence).
    @Published private(set) var isUnlocked = false
    @Published private(set) var deviceActive = false      // a license is stored on this Mac
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var onGrace = false           // unlocked via offline grace

    private let graceWindow: TimeInterval = 30 * 24 * 60 * 60   // 30 days

    private enum K {
        static let key         = "license_key"
        static let instance    = "instance_id"
        static let validatedAt  = "last_validated_at"   // epoch seconds, as string
        static let provider     = "license_provider"    // which backend issued the stored key
    }

    /// Which licensing backend a stored activation belongs to. New activations are
    /// always Polar; the Lemon Squeezy case exists only to keep pre-migration beta
    /// testers (whose Keychain has no provider tag) validating against their
    /// test-store key until they re-activate with a Polar key.
    private enum Provider: String {
        case polar
        case lemonSqueezy = "lemonsqueezy"
    }

    // MARK: Stored state

    private var storedKey: String?        { Keychain.get(K.key) }
    private var storedInstance: String?   { Keychain.get(K.instance) }
    private var lastValidatedAt: Date? {
        guard let s = Keychain.get(K.validatedAt), let t = TimeInterval(s) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// A missing tag means the key was activated before the Polar migration, so
    /// it's a Lemon Squeezy test-store key — validate it there, not against Polar.
    private var storedProvider: Provider {
        guard let raw = Keychain.get(K.provider), let p = Provider(rawValue: raw) else {
            return .lemonSqueezy
        }
        return p
    }

    init() {
        // Apply grace synchronously so the UI reflects paid status instantly at
        // launch without waiting on the network. `validateOnLaunch()` then
        // confirms/refreshes in the background.
        deviceActive = (storedKey != nil && storedInstance != nil)
        if deviceActive, withinGrace() {
            isUnlocked = true
            onGrace = true
            statusMessage = "License active"
        }
    }

    // MARK: Launch validation (non-blocking; safe to call from .task)

    func validateOnLaunch() async {
        guard let key = storedKey, let instance = storedInstance else {
            return // no license on this Mac → trial
        }

        // Validate against whichever backend issued this activation. The three
        // outcomes are handled identically regardless of provider.
        let outcome: ValidationOutcome
        switch storedProvider {
        case .polar:        outcome = await validatePolar(key: key, activationID: instance)
        case .lemonSqueezy: outcome = await validateLemonSqueezy(key: key, instanceID: instance)
        }

        switch outcome {
        case .active:
            markValidatedNow()
            isUnlocked = true
            onGrace = false
            statusMessage = "License active"
        case .inactive:
            // Confirmed not active (revoked / disabled / not found): revoke now.
            lapse()
        case .connectivity:
            // Couldn't reach the server — ride the grace window at full function.
            if withinGrace() {
                isUnlocked = true
                onGrace = true
                statusMessage = "License active (offline)"
            } else {
                isUnlocked = false
                onGrace = false
                statusMessage = "Connect to the internet to confirm your license."
            }
        }
    }

    private enum ValidationOutcome { case active, inactive, connectivity }

    private func validatePolar(key: String, activationID: String) async -> ValidationOutcome {
        do {
            let resp = try await PolarClient.shared.validate(key: key, activationID: activationID)
            return resp.status == "granted" ? .active : .inactive
        } catch let error as PolarError where error.isConnectivity {
            return .connectivity
        } catch {
            return .inactive
        }
    }

    private func validateLemonSqueezy(key: String, instanceID: String) async -> ValidationOutcome {
        do {
            let resp = try await LemonSqueezyClient.shared.validate(key: key, instanceID: instanceID)
            return (resp.valid == true && resp.licenseKey?.status == "active") ? .active : .inactive
        } catch let error as LemonSqueezyError where error.isConnectivity {
            return .connectivity
        } catch {
            return .inactive
        }
    }

    // MARK: Activation

    func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        isWorking = true
        statusMessage = ""
        defer { isWorking = false }

        do {
            let resp = try await PolarClient.shared.activate(
                key: key,
                label: Host.current().localizedName ?? "This Mac"
            )
            guard let activationID = resp.id else {
                statusMessage = "Activation failed. Please try again."
                return
            }
            Keychain.set(key, for: K.key)
            Keychain.set(activationID, for: K.instance)
            Keychain.set(Provider.polar.rawValue, for: K.provider)
            markValidatedNow()
            deviceActive = true
            isUnlocked = true
            onGrace = false
            statusMessage = "License activated"
        } catch let error as PolarError {
            statusMessage = error.localizedDescription
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: Deactivation (free this Mac's slot)

    func deactivateDevice() async {
        guard let key = storedKey, let instance = storedInstance else {
            clearLocal()
            return
        }
        isWorking = true
        statusMessage = ""
        defer { isWorking = false }

        do {
            switch storedProvider {
            case .polar:
                try await PolarClient.shared.deactivate(key: key, activationID: instance)
            case .lemonSqueezy:
                _ = try await LemonSqueezyClient.shared.deactivate(key: key, instanceID: instance)
            }
            clearLocal()
            statusMessage = "This Mac has been deactivated."
        } catch let error as PolarError {
            // Don't clear locally if the server slot couldn't be freed, or it
            // would orphan the activation. Surface the reason instead.
            statusMessage = error.localizedDescription
        } catch let error as LemonSqueezyError {
            statusMessage = error.localizedDescription
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: Helpers

    private func withinGrace() -> Bool {
        guard let last = lastValidatedAt else { return false }
        return Date().timeIntervalSince(last) <= graceWindow
    }

    private func markValidatedNow() {
        Keychain.set(String(Date().timeIntervalSince1970), for: K.validatedAt)
    }

    /// Confirmed-inactive subscription: lock to trial but keep the key/instance
    /// so a renewal can be re-confirmed without re-entering anything.
    private func lapse() {
        Keychain.delete(K.validatedAt)
        isUnlocked = false
        onGrace = false
        statusMessage = "Your subscription is no longer active. Renew to continue."
    }

    /// Remove all local license state (after a successful deactivation).
    private func clearLocal() {
        Keychain.delete(K.key)
        Keychain.delete(K.instance)
        Keychain.delete(K.validatedAt)
        Keychain.delete(K.provider)
        deviceActive = false
        isUnlocked = false
        onGrace = false
    }
}

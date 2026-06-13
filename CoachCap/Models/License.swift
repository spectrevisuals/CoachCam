import Foundation

/// Manages CoachCam's Lemon Squeezy subscription license.
///
/// Unlock model:
/// - A key is activated once per Mac (`instance_name` = hardware UUID), giving
///   one activation slot per key. Reuse on a second Mac is refused by the server.
/// - `validate` runs on launch. A confirmed `active` refreshes the grace clock;
///   a confirmed *not* active revokes immediately and overrides grace.
/// - When the server is unreachable we trust the last successful validation for
///   up to 30 days (full paid functionality), so offline coaches are never
///   dropped to the trial just for lacking a connection.
///
/// This is a timestamp-trust model, not cryptographically signed. The validation
/// step is isolated (`refreshFromServer`) so a signed-token provider (e.g.
/// Keyforge) could replace it later without changing the UI surface.
@MainActor
final class LicenseManager: ObservableObject {

    // UI-facing surface (unchanged: `isUnlocked` still gates the trial cap).
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
    }

    // MARK: Stored state

    private var storedKey: String?        { Keychain.get(K.key) }
    private var storedInstance: String?   { Keychain.get(K.instance) }
    private var lastValidatedAt: Date? {
        guard let s = Keychain.get(K.validatedAt), let t = TimeInterval(s) else { return nil }
        return Date(timeIntervalSince1970: t)
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
        do {
            let resp = try await LemonSqueezyClient.shared.validate(key: key, instanceID: instance)
            if resp.valid == true && resp.licenseKey?.status == "active" {
                markValidatedNow()
                isUnlocked = true
                onGrace = false
                statusMessage = "License active"
            } else {
                // Confirmed not active (expired / disabled / inactive): revoke now.
                lapse()
            }
        } catch let error as LemonSqueezyError where error.isConnectivity {
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
        } catch {
            // Definitive server rejection (wrong product, etc.): treat as lapsed.
            lapse()
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
            let resp = try await LemonSqueezyClient.shared.activate(
                key: key,
                instanceName: DeviceIdentity.hardwareUUID
            )
            guard resp.activated == true, let instanceID = resp.instance?.id else {
                statusMessage = "Activation failed. Please try again."
                return
            }
            Keychain.set(key, for: K.key)
            Keychain.set(instanceID, for: K.instance)
            markValidatedNow()
            deviceActive = true
            isUnlocked = true
            onGrace = false
            statusMessage = "License activated"
        } catch let error as LemonSqueezyError {
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
            _ = try await LemonSqueezyClient.shared.deactivate(key: key, instanceID: instance)
            clearLocal()
            statusMessage = "This Mac has been deactivated."
        } catch let error as LemonSqueezyError {
            // Don't clear locally if the server slot couldn't be freed, or it
            // would orphan the activation. Surface the reason instead.
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
        deviceActive = false
        isUnlocked = false
        onGrace = false
    }
}

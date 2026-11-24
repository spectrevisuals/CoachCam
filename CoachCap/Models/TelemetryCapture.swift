import AVFoundation

// Telemetry vocabulary for capture devices and permissions.
//
// Each function reduces an AVFoundation object to one constant token. A device's name, unique
// id, model and manufacturer never leave this file: names are often a person's ("Sam's iPhone
// Camera", "Sam's AirPods") and unique ids are hardware identifiers.

extension Telemetry.Transport {

    /// How a camera or microphone is attached: built-in, USB, Bluetooth, Continuity / virtual,
    /// or anything else. Reads only `isContinuityCamera` and `transportType`.
    init(_ device: AVCaptureDevice) {
        if device.isContinuityCamera {
            self = .continuityOrVirtual
            return
        }
        // `transportType` is a four-character code (IOKit/audio/IOAudioTypes.h,
        // CoreAudio/AudioHardwareBase.h).
        switch device.transportType {
        case Self.code("bltn"):
            self = .builtIn
        case Self.code("usb "):
            self = .usb
        case Self.code("blue"), Self.code("blea"):                      // Bluetooth, Bluetooth LE
            self = .bluetooth
        case Self.code("ccwd"), Self.code("ccwl"), Self.code("ccap"),   // Continuity, wired / wireless
             Self.code("virt"), Self.code("grup"):                      // virtual, aggregate
            self = .continuityOrVirtual
        default:
            self = .other
        }
    }

    /// The transport class as a compile-time constant token.
    var token: StaticString {
        switch self {
        case .builtIn: return "built_in"
        case .usb: return "usb"
        case .bluetooth: return "bluetooth"
        case .continuityOrVirtual: return "continuity_or_virtual"
        case .other: return "other"
        }
    }

    /// A four-character code as the `Int32` that `transportType` returns.
    private static func code(_ text: StaticString) -> Int32 {
        var value: UInt32 = 0
        text.withUTF8Buffer { bytes in
            for byte in bytes.prefix(4) {
                value = (value << 8) | UInt32(byte)
            }
        }
        return Int32(bitPattern: value)
    }
}

extension Telemetry {

    /// The transport class of a device as a token, or `none` when there is no device.
    static func transportToken(_ device: AVCaptureDevice?) -> StaticString {
        device.map { Transport($0).token } ?? "none"
    }

    /// A camera / microphone authorisation status as a token. Reading the status never prompts.
    static func authorizationToken(_ status: AVAuthorizationStatus) -> StaticString {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }
}

import Foundation

/// Standard PTP (ISO 15740) operation codes plus the Fujifilm vendor ones we use.
public enum PTPOperation: UInt16, Sendable {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003
    case initiateCapture = 0x100E
    case getDevicePropDesc = 0x1014
    case getDevicePropValue = 0x1015
    case setDevicePropValue = 0x1016
    case terminateOpenCapture = 0x1018
    case initiateOpenCapture = 0x101C
}

public enum PTPContainerType: UInt16, Sendable {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

public struct PTPResponseCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let ok = PTPResponseCode(rawValue: 0x2001)
    public static let generalError = PTPResponseCode(rawValue: 0x2002)
    public static let sessionNotOpen = PTPResponseCode(rawValue: 0x2003)
    public static let operationNotSupported = PTPResponseCode(rawValue: 0x2005)
    public static let devicePropNotSupported = PTPResponseCode(rawValue: 0x200A)
    public static let invalidDevicePropValue = PTPResponseCode(rawValue: 0x201C)
    public static let deviceBusy = PTPResponseCode(rawValue: 0x2019)
    public static let sessionAlreadyOpen = PTPResponseCode(rawValue: 0x201E)

    public var description: String {
        switch self {
        case .ok: return "ok"
        case .generalError: return "general error"
        case .sessionNotOpen: return "session not open"
        case .operationNotSupported: return "operation not supported"
        case .devicePropNotSupported: return "property not supported"
        case .invalidDevicePropValue: return "invalid value"
        case .deviceBusy: return "camera busy"
        case .sessionAlreadyOpen: return "session already open"
        default: return String(format: "0x%04X", rawValue)
        }
    }
}

/// Fujifilm device property codes used by this app.
///
/// Sources: eggricesoy/filmkit (MIT, USB captures of X RAW STUDIO) for the custom-setting block,
/// petabyt/libfuji (MIT) for the Wi-Fi remote state machine.
public enum FujiProp {
    // Custom settings (C1–C7). Select the slot with `presetSlot`, then read/write the block.
    public static let presetSlot: UInt16 = 0xD18C
    public static let presetName: UInt16 = 0xD18D
    public static let imageSize: UInt16 = 0xD18E
    public static let imageQuality: UInt16 = 0xD18F
    public static let dynamicRange: UInt16 = 0xD190
    public static let unknownD191: UInt16 = 0xD191
    public static let filmSimulation: UInt16 = 0xD192
    public static let monoWarmCool: UInt16 = 0xD193
    public static let monoMagentaGreen: UInt16 = 0xD194
    public static let grainEffect: UInt16 = 0xD195
    public static let colorChrome: UInt16 = 0xD196
    public static let colorChromeBlue: UInt16 = 0xD197
    public static let smoothSkin: UInt16 = 0xD198
    public static let whiteBalance: UInt16 = 0xD199
    public static let wbShiftRed: UInt16 = 0xD19A
    public static let wbShiftBlue: UInt16 = 0xD19B
    public static let wbColorTemp: UInt16 = 0xD19C
    public static let highlightTone: UInt16 = 0xD19D
    public static let shadowTone: UInt16 = 0xD19E
    public static let color: UInt16 = 0xD19F
    public static let sharpness: UInt16 = 0xD1A0
    public static let noiseReduction: UInt16 = 0xD1A1
    public static let clarity: UInt16 = 0xD1A2
    public static let longExposureNR: UInt16 = 0xD1A3
    public static let colorSpace: UInt16 = 0xD1A4
    public static let unknownD1A5: UInt16 = 0xD1A5

    public static let presetBlock: ClosedRange<UInt16> = 0xD18E ... 0xD1A5

    // Wi-Fi remote state machine.
    public static let eventsList: UInt16 = 0xD212
    public static let cameraState: UInt16 = 0xDF00
    public static let clientState: UInt16 = 0xDF01
    public static let imageGetVersion: UInt16 = 0xDF21
    public static let getObjectVersion: UInt16 = 0xDF22
    public static let remoteVersion: UInt16 = 0xDF24
    public static let remoteGetObjectVersion: UInt16 = 0xDF25
}

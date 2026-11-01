import Foundation

/// A film simulation recipe in human units (the values you'd see in the camera's menus).
///
/// Encoding to the camera's custom-setting properties lives in `PresetCodec`.
public struct Recipe: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var filmSimulation: FilmSimulation
    public var grain: GrainEffect
    public var colorChrome: EffectStrength
    public var colorChromeBlue: EffectStrength
    public var smoothSkin: EffectStrength
    public var whiteBalance: WhiteBalance
    /// Only used when `whiteBalance == .kelvin`.
    public var kelvin: Int
    public var wbShiftRed: Int
    public var wbShiftBlue: Int
    public var dynamicRange: DynamicRange
    public var highlight: Double
    public var shadow: Double
    public var color: Int
    public var sharpness: Int
    public var noiseReduction: Int
    public var clarity: Int
    /// Monochromatic colour, only used by B&W simulations.
    public var monoWarmCool: Int
    public var monoMagentaGreen: Int

    /// The camera does not store these in custom settings, so they're kept as reminders.
    public var isoNote: String
    public var exposureNote: String
    public var notes: String
    public var source: String
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "untitled",
        filmSimulation: FilmSimulation = .provia,
        grain: GrainEffect = .off,
        colorChrome: EffectStrength = .off,
        colorChromeBlue: EffectStrength = .off,
        smoothSkin: EffectStrength = .off,
        whiteBalance: WhiteBalance = .auto,
        kelvin: Int = 5500,
        wbShiftRed: Int = 0,
        wbShiftBlue: Int = 0,
        dynamicRange: DynamicRange = .dr100,
        highlight: Double = 0,
        shadow: Double = 0,
        color: Int = 0,
        sharpness: Int = 0,
        noiseReduction: Int = 0,
        clarity: Int = 0,
        monoWarmCool: Int = 0,
        monoMagentaGreen: Int = 0,
        isoNote: String = "",
        exposureNote: String = "",
        notes: String = "",
        source: String = "",
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.filmSimulation = filmSimulation
        self.grain = grain
        self.colorChrome = colorChrome
        self.colorChromeBlue = colorChromeBlue
        self.smoothSkin = smoothSkin
        self.whiteBalance = whiteBalance
        self.kelvin = kelvin
        self.wbShiftRed = wbShiftRed
        self.wbShiftBlue = wbShiftBlue
        self.dynamicRange = dynamicRange
        self.highlight = highlight
        self.shadow = shadow
        self.color = color
        self.sharpness = sharpness
        self.noiseReduction = noiseReduction
        self.clarity = clarity
        self.monoWarmCool = monoWarmCool
        self.monoMagentaGreen = monoMagentaGreen
        self.isoNote = isoNote
        self.exposureNote = exposureNote
        self.notes = notes
        self.source = source
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Decodes leniently: missing keys fall back to defaults so older or hand-written files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Recipe()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback
        }
        id = v(.id, UUID())
        name = v(.name, d.name)
        filmSimulation = v(.filmSimulation, d.filmSimulation)
        grain = v(.grain, d.grain)
        colorChrome = v(.colorChrome, d.colorChrome)
        colorChromeBlue = v(.colorChromeBlue, d.colorChromeBlue)
        smoothSkin = v(.smoothSkin, d.smoothSkin)
        whiteBalance = v(.whiteBalance, d.whiteBalance)
        kelvin = v(.kelvin, d.kelvin)
        wbShiftRed = v(.wbShiftRed, d.wbShiftRed)
        wbShiftBlue = v(.wbShiftBlue, d.wbShiftBlue)
        dynamicRange = v(.dynamicRange, d.dynamicRange)
        highlight = v(.highlight, d.highlight)
        shadow = v(.shadow, d.shadow)
        color = v(.color, d.color)
        sharpness = v(.sharpness, d.sharpness)
        noiseReduction = v(.noiseReduction, d.noiseReduction)
        clarity = v(.clarity, d.clarity)
        monoWarmCool = v(.monoWarmCool, d.monoWarmCool)
        monoMagentaGreen = v(.monoMagentaGreen, d.monoMagentaGreen)
        isoNote = v(.isoNote, d.isoNote)
        exposureNote = v(.exposureNote, d.exposureNote)
        notes = v(.notes, d.notes)
        source = v(.source, d.source)
        tags = v(.tags, d.tags)
        createdAt = v(.createdAt, d.createdAt)
        updatedAt = v(.updatedAt, d.updatedAt)
    }

    /// Same settings, ignoring identity, notes and timestamps. Used to spot duplicates and to verify writes.
    public func sameSettings(as o: Recipe) -> Bool {
        var a = self.normalized(), b = o.normalized()
        a.id = b.id; a.name = b.name
        a.isoNote = ""; b.isoNote = ""; a.exposureNote = ""; b.exposureNote = ""
        a.notes = ""; b.notes = ""; a.source = ""; b.source = ""; a.tags = []; b.tags = []
        a.createdAt = b.createdAt; a.updatedAt = b.updatedAt
        return a == b
    }

    /// Clamps every value to what an X-T30 II accepts and zeroes fields the simulation ignores.
    public func normalized() -> Recipe {
        var r = self
        r.name = String(r.name.prefix(Recipe.maxNameLength))
        r.kelvin = Self.clamp(r.kelvin, 2500, 10000) / 10 * 10
        r.wbShiftRed = Self.clamp(r.wbShiftRed, -9, 9)
        r.wbShiftBlue = Self.clamp(r.wbShiftBlue, -9, 9)
        r.highlight = (min(max(r.highlight, -2), 4) * 2).rounded() / 2
        r.shadow = (min(max(r.shadow, -2), 4) * 2).rounded() / 2
        r.color = Self.clamp(r.color, -4, 4)
        r.sharpness = Self.clamp(r.sharpness, -4, 4)
        r.noiseReduction = Self.clamp(r.noiseReduction, -4, 4)
        r.clarity = Self.clamp(r.clarity, -5, 5)
        r.monoWarmCool = Self.clamp(r.monoWarmCool, -9, 9)
        r.monoMagentaGreen = Self.clamp(r.monoMagentaGreen, -9, 9)
        if r.filmSimulation.isMonochrome {
            r.color = 0
        } else {
            r.monoWarmCool = 0
            r.monoMagentaGreen = 0
        }
        return r
    }

    public static let maxNameLength = 25

    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}

public enum FilmSimulation: String, Codable, CaseIterable, Sendable, Identifiable {
    case provia, velvia, astia, classicChrome, proNegHi, proNegStd, classicNeg, eterna, eternaBleachBypass
    case acros, acrosYellow, acrosRed, acrosGreen
    case monochrome, monochromeYellow, monochromeRed, monochromeGreen, sepia
    // Present on newer bodies only; kept so recipes from other cameras round-trip.
    case nostalgicNeg, realaAce

    public var id: String { rawValue }

    /// Camera code for property 0xD192.
    public var code: UInt16 {
        switch self {
        case .provia: return 0x01
        case .velvia: return 0x02
        case .astia: return 0x03
        case .proNegHi: return 0x04
        case .proNegStd: return 0x05
        case .monochrome: return 0x06
        case .monochromeYellow: return 0x07
        case .monochromeRed: return 0x08
        case .monochromeGreen: return 0x09
        case .sepia: return 0x0A
        case .classicChrome: return 0x0B
        case .acros: return 0x0C
        case .acrosYellow: return 0x0D
        case .acrosRed: return 0x0E
        case .acrosGreen: return 0x0F
        case .eterna: return 0x10
        case .classicNeg: return 0x11
        case .eternaBleachBypass: return 0x12
        case .nostalgicNeg: return 0x13
        case .realaAce: return 0x14
        }
    }

    public init?(code: UInt16) {
        guard let s = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = s
    }

    public var label: String {
        switch self {
        case .provia: return "Provia / Standard"
        case .velvia: return "Velvia / Vivid"
        case .astia: return "Astia / Soft"
        case .classicChrome: return "Classic Chrome"
        case .proNegHi: return "Pro Neg. Hi"
        case .proNegStd: return "Pro Neg. Std"
        case .classicNeg: return "Classic Negative"
        case .eterna: return "Eterna / Cinema"
        case .eternaBleachBypass: return "Eterna Bleach Bypass"
        case .acros: return "Acros"
        case .acrosYellow: return "Acros + Ye Filter"
        case .acrosRed: return "Acros + R Filter"
        case .acrosGreen: return "Acros + G Filter"
        case .monochrome: return "Monochrome"
        case .monochromeYellow: return "Monochrome + Ye Filter"
        case .monochromeRed: return "Monochrome + R Filter"
        case .monochromeGreen: return "Monochrome + G Filter"
        case .sepia: return "Sepia"
        case .nostalgicNeg: return "Nostalgic Neg."
        case .realaAce: return "Reala Ace"
        }
    }

    public var isMonochrome: Bool {
        switch self {
        case .acros, .acrosYellow, .acrosRed, .acrosGreen,
             .monochrome, .monochromeYellow, .monochromeRed, .monochromeGreen, .sepia:
            return true
        default:
            return false
        }
    }

    /// Simulations available on the X-T30 II.
    public var onXT30II: Bool { self != .nostalgicNeg && self != .realaAce }
}

public enum EffectStrength: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, weak, strong
    public var id: String { rawValue }
    /// Custom-setting encoding is 1-based: 1 off, 2 weak, 3 strong.
    public var code: UInt16 { switch self {
        case .off: return 1
        case .weak: return 2
        case .strong: return 3
        } }
    public init?(code: UInt16) {
        switch code { case 1: self = .off; case 2: self = .weak; case 3: self = .strong; default: return nil }
    }
    public var label: String { rawValue }
}

public enum GrainEffect: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, weakSmall, strongSmall, weakLarge, strongLarge
    public var id: String { rawValue }
    public var code: UInt16 {
        switch self {
        case .off: return 1
        case .weakSmall: return 2
        case .strongSmall: return 3
        case .weakLarge: return 4
        case .strongLarge: return 5
        }
    }
    public init?(code: UInt16) {
        guard let g = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = g
    }
    public var label: String {
        switch self {
        case .off: return "off"
        case .weakSmall: return "weak, small"
        case .strongSmall: return "strong, small"
        case .weakLarge: return "weak, large"
        case .strongLarge: return "strong, large"
        }
    }
}

public enum WhiteBalance: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto, autoWhitePriority, autoAmbiencePriority, kelvin, daylight, shade
    case fluorescent1, fluorescent2, fluorescent3, incandescent, underwater

    public var id: String { rawValue }

    /// Camera code for property 0xD199.
    public var code: UInt16 {
        switch self {
        case .auto: return 0x0002
        case .daylight: return 0x0004
        case .incandescent: return 0x0006
        case .underwater: return 0x0008
        case .fluorescent1: return 0x8001
        case .fluorescent2: return 0x8002
        case .fluorescent3: return 0x8003
        case .shade: return 0x8006
        case .kelvin: return 0x8007
        case .autoWhitePriority: return 0x8020 // unverified: inferred from AmbiencePriority = 0x8021
        case .autoAmbiencePriority: return 0x8021
        }
    }

    public init?(code: UInt16) {
        guard let w = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = w
    }

    public var label: String {
        switch self {
        case .auto: return "auto"
        case .autoWhitePriority: return "auto, white priority"
        case .autoAmbiencePriority: return "auto, ambience priority"
        case .kelvin: return "color temperature"
        case .daylight: return "daylight"
        case .shade: return "shade"
        case .fluorescent1: return "fluorescent 1"
        case .fluorescent2: return "fluorescent 2"
        case .fluorescent3: return "fluorescent 3"
        case .incandescent: return "incandescent"
        case .underwater: return "underwater"
        }
    }
}

public enum DynamicRange: String, Codable, CaseIterable, Sendable, Identifiable {
    case dr100, dr200, dr400
    public var id: String { rawValue }
    /// Custom-setting encoding is the raw percentage.
    public var code: UInt16 { switch self {
        case .dr100: return 100
        case .dr200: return 200
        case .dr400: return 400
        } }
    public init?(code: UInt16) {
        switch code { case 100: self = .dr100; case 200: self = .dr200; case 400: self = .dr400; default: return nil }
    }
    public var label: String { "DR\(code)" }
    /// The camera needs at least this ISO before it accepts the setting.
    public var minimumISO: Int { switch self {
        case .dr100: return 160
        case .dr200: return 320
        case .dr400: return 640
        } }
}

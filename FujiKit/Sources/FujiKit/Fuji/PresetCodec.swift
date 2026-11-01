import Foundation

/// One property write in a custom-setting transfer.
public struct PropWrite: Equatable, Sendable {
    public var code: UInt16
    public var value: Data

    public init(_ code: UInt16, _ value: Data) {
        self.code = code
        self.value = value
    }

    public static func u16(_ code: UInt16, _ v: UInt16) -> PropWrite {
        var w = ByteWriter(); w.u16(v); return PropWrite(code, w.data)
    }

    public static func i16(_ code: UInt16, _ v: Int) -> PropWrite {
        var w = ByteWriter(); w.i16(Int16(clamping: v)); return PropWrite(code, w.data)
    }
}

/// Raw contents of one custom-setting slot as read from the camera.
public struct CameraPreset: Equatable, Sendable {
    public var slot: Int
    public var name: String
    public var raw: [UInt16: Data]

    public init(slot: Int, name: String, raw: [UInt16: Data]) {
        self.slot = slot
        self.name = name
        self.raw = raw
    }
}

/// Translates between `Recipe` and the camera's custom-setting properties (0xD18E–0xD1A5).
///
/// Encodings and write order come from eggricesoy/filmkit's Wireshark captures of X RAW STUDIO.
/// Notable quirks:
/// - Effects are 1-based (1 off, 2 weak, 3 strong); grain is a flat enum 1–5.
/// - Dynamic range is the raw percentage (100/200/400).
/// - Tone values are ×10 (+1.5 → 15).
/// - High ISO NR uses a non-linear table.
/// - Colour temperature must be written right after the WB mode, and only for Kelvin WB.
/// - On the X-T30 II, smooth skin (0xD198) and long-exposure NR (0xD1A3) answer "invalid value"
///   to any write, even of their current value, so smooth skin is never sent and properties we
///   don't edit are only written when no base read is available.
/// - Colour is omitted for B&W sims; mono WC/MG are omitted for colour sims and when zero
///   (the camera rejects a written zero).
public enum PresetCodec {
    static let nrEncode: [Int: UInt16] = [
        -4: 0x8000, -3: 0x7000, -2: 0x4000, -1: 0x3000,
        0: 0x2000, 1: 0x1000, 2: 0x0000, 3: 0x6000, 4: 0x5000,
    ]
    static let nrDecode: [UInt16: Int] = Dictionary(uniqueKeysWithValues: nrEncode.map { ($1, $0) })

    /// Values seen on cameras for properties we don't edit. Used only when no base read is available.
    static let unknownDefaults: [UInt16: UInt16] = [
        FujiProp.imageSize: 7,
        FujiProp.imageQuality: 4,
        FujiProp.unknownD191: 0,
        FujiProp.longExposureNR: 1,
        FujiProp.colorSpace: 1,
        FujiProp.unknownD1A5: 7,
    ]

    /// Builds the ordered list of writes for a recipe.
    /// - Parameter base: the slot's current raw values; untouched properties are written back unchanged.
    public static func encode(_ input: Recipe, base: [UInt16: Data] = [:]) -> [PropWrite] {
        let r = input.normalized()
        let mono = r.filmSimulation.isMonochrome

        var out: [PropWrite] = []
        // Properties we don't edit: leave them alone when the slot was read first (writing them
        // back gets "invalid value" for some), fill in known defaults otherwise.
        func passthrough(_ code: UInt16) {
            guard base[code] == nil else { return }
            out.append(.u16(code, unknownDefaults[code] ?? 0))
        }

        passthrough(FujiProp.imageSize)
        passthrough(FujiProp.imageQuality)
        out.append(.u16(FujiProp.dynamicRange, r.dynamicRange.code))
        passthrough(FujiProp.unknownD191)
        out.append(.u16(FujiProp.filmSimulation, r.filmSimulation.code))
        if mono && r.monoWarmCool != 0 { out.append(.i16(FujiProp.monoWarmCool, r.monoWarmCool * 10)) }
        if mono && r.monoMagentaGreen != 0 { out.append(.i16(FujiProp.monoMagentaGreen, r.monoMagentaGreen * 10)) }
        out.append(.u16(FujiProp.grainEffect, r.grain.code))
        out.append(.u16(FujiProp.colorChrome, r.colorChrome.code))
        out.append(.u16(FujiProp.colorChromeBlue, r.colorChromeBlue.code))
        out.append(.u16(FujiProp.whiteBalance, r.whiteBalance.code))
        if r.whiteBalance == .kelvin { out.append(.u16(FujiProp.wbColorTemp, UInt16(r.kelvin))) }
        out.append(.i16(FujiProp.wbShiftRed, r.wbShiftRed))
        out.append(.i16(FujiProp.wbShiftBlue, r.wbShiftBlue))
        out.append(.i16(FujiProp.highlightTone, Int((r.highlight * 10).rounded())))
        out.append(.i16(FujiProp.shadowTone, Int((r.shadow * 10).rounded())))
        if !mono { out.append(.i16(FujiProp.color, r.color * 10)) }
        out.append(.i16(FujiProp.sharpness, r.sharpness * 10))
        out.append(.u16(FujiProp.noiseReduction, nrEncode[r.noiseReduction] ?? 0x2000))
        out.append(.i16(FujiProp.clarity, r.clarity * 10))
        passthrough(FujiProp.longExposureNR)
        passthrough(FujiProp.colorSpace)
        passthrough(FujiProp.unknownD1A5)
        return out
    }

    /// Reads a recipe out of a slot's raw values. Unknown or missing values keep the recipe defaults.
    public static func decode(_ preset: CameraPreset) -> Recipe {
        let raw = preset.raw
        func u16(_ c: UInt16) -> UInt16? {
            guard let d = raw[c], d.count >= 2 else { return nil }
            var r = ByteReader(d); return try? r.u16()
        }
        func i16(_ c: UInt16) -> Int? { u16(c).map { Int(Int16(bitPattern: $0)) } }
        func tone(_ c: UInt16) -> Double? {
            guard let v = u16(c), v != 0x8000 else { return nil } // 0x8000 = "not set"
            return Double(Int16(bitPattern: v)) / 10
        }

        var r = Recipe(name: preset.name.isEmpty ? "C\(preset.slot)" : preset.name)
        r.source = "camera C\(preset.slot)"
        if let v = u16(FujiProp.filmSimulation), let s = FilmSimulation(code: v) { r.filmSimulation = s }
        if let v = u16(FujiProp.dynamicRange), let s = DynamicRange(code: v) { r.dynamicRange = s }
        if let v = u16(FujiProp.grainEffect), let s = GrainEffect(code: v) { r.grain = s }
        if let v = u16(FujiProp.colorChrome), let s = EffectStrength(code: v) { r.colorChrome = s }
        if let v = u16(FujiProp.colorChromeBlue), let s = EffectStrength(code: v) { r.colorChromeBlue = s }
        if let v = u16(FujiProp.smoothSkin), let s = EffectStrength(code: v) { r.smoothSkin = s }
        if let v = u16(FujiProp.whiteBalance), let s = WhiteBalance(code: v) { r.whiteBalance = s }
        if let v = u16(FujiProp.wbColorTemp), v >= 2500 { r.kelvin = Int(v) }
        if let v = i16(FujiProp.wbShiftRed) { r.wbShiftRed = v }
        if let v = i16(FujiProp.wbShiftBlue) { r.wbShiftBlue = v }
        if let v = tone(FujiProp.highlightTone) { r.highlight = v }
        if let v = tone(FujiProp.shadowTone) { r.shadow = v }
        if let v = tone(FujiProp.color) { r.color = Int(v.rounded()) }
        if let v = tone(FujiProp.sharpness) { r.sharpness = Int(v.rounded()) }
        if let v = tone(FujiProp.clarity) { r.clarity = Int(v.rounded()) }
        if let v = u16(FujiProp.noiseReduction), let n = nrDecode[v] { r.noiseReduction = n }
        if r.filmSimulation.isMonochrome {
            if let v = tone(FujiProp.monoWarmCool) { r.monoWarmCool = Int(v.rounded()) }
            if let v = tone(FujiProp.monoMagentaGreen) { r.monoMagentaGreen = Int(v.rounded()) }
        }
        return r.normalized()
    }
}

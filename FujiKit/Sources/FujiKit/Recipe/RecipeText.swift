import Foundation

/// Plain-text recipes in the "Key: value" style used by Fuji X Weekly and most recipe sites.
///
/// ```
/// Film Simulation: Classic Chrome
/// Grain Effect: Weak, Small
/// Color Chrome Effect: Strong
/// Color Chrome FX Blue: Off
/// White Balance: 5200K, +2 Red & -4 Blue
/// Dynamic Range: DR400
/// Highlight: -1
/// Shadow: +0.5
/// Color: +2
/// Sharpness: -2
/// High ISO NR: -4
/// Clarity: -2
/// ISO: Auto, up to ISO 6400
/// Exposure Compensation: +1/3 to +2/3
/// ```
public enum RecipeText {
    public struct ParseResult: Sendable {
        public var recipe: Recipe
        /// Lines that looked like settings but couldn't be understood.
        public var unrecognized: [String]
    }

    public static func parse(_ text: String, fallbackName: String = "imported") -> ParseResult {
        var r = Recipe(name: fallbackName)
        var unrecognized: [String] = []
        var sawName = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "•-*>"))
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else {
                if !sawName { r.name = String(line.prefix(Recipe.maxNameLength)); sawName = true }
                continue
            }
            let key = normalizeKey(String(line[..<colon]))
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let lv = value.lowercased()

            switch key {
            case "name", "recipe", "title":
                r.name = String(value.prefix(Recipe.maxNameLength)); sawName = true
            case "filmsimulation", "film", "simulation", "filmsim":
                if let s = filmSimulation(lv) { r.filmSimulation = s } else { unrecognized.append(line) }
            case "grain", "graineffect":
                if let g = grain(lv) { r.grain = g } else { unrecognized.append(line) }
            case "colorchrome", "colorchromeeffect", "colourchromeeffect", "cce":
                if let e = effect(lv) { r.colorChrome = e } else { unrecognized.append(line) }
            case "colorchromefxblue", "colorchromeeffectblue", "colourchromefxblue", "ccfxblue", "fxblue":
                if let e = effect(lv) { r.colorChromeBlue = e } else { unrecognized.append(line) }
            case "smoothskin", "smoothskineffect":
                if let e = effect(lv) { r.smoothSkin = e } else { unrecognized.append(line) }
            case "whitebalance", "wb":
                if !whiteBalance(lv, into: &r) { unrecognized.append(line) }
            case "dynamicrange", "dr":
                if let d = dynamicRange(lv) { r.dynamicRange = d } else { unrecognized.append(line) }
            case "highlight", "highlights", "highlighttone":
                if let v = number(lv) { r.highlight = v } else { unrecognized.append(line) }
            case "shadow", "shadows", "shadowtone":
                if let v = number(lv) { r.shadow = v } else { unrecognized.append(line) }
            case "tonecurve", "tone":
                // "H+1 S-1" or "+1 H & -1 S"
                let hs = toneCurve(lv)
                if let h = hs.h { r.highlight = h }
                if let s = hs.s { r.shadow = s }
                if hs.h == nil && hs.s == nil { unrecognized.append(line) }
            case "color", "colour", "saturation":
                if let v = number(lv) { r.color = Int(v.rounded()) } else { unrecognized.append(line) }
            case "sharpness", "sharpening":
                if let v = number(lv) { r.sharpness = Int(v.rounded()) } else { unrecognized.append(line) }
            case "highisonr", "noisereduction", "nr", "highisonoisereduction":
                if let v = number(lv) { r.noiseReduction = Int(v.rounded()) } else { unrecognized.append(line) }
            case "clarity":
                if let v = number(lv) { r.clarity = Int(v.rounded()) } else { unrecognized.append(line) }
            case "monochromaticcolor", "monochromaticcolour", "monocolor", "mono":
                let wc = signedNumber(before: ["wc", "warm"], in: lv)
                let mg = signedNumber(before: ["mg", "magenta"], in: lv)
                if let wc { r.monoWarmCool = Int(wc) }
                if let mg { r.monoMagentaGreen = Int(mg) }
                if wc == nil && mg == nil { unrecognized.append(line) }
            case "iso":
                r.isoNote = value
            case "exposurecompensation", "exposure", "ev", "exposurecomp":
                r.exposureNote = value
            case "notes", "note":
                r.notes = value
            case "source", "url", "link":
                r.source = value
            default:
                unrecognized.append(line)
            }
        }
        return ParseResult(recipe: r.normalized(), unrecognized: unrecognized)
    }

    public static func format(_ input: Recipe) -> String {
        let r = input.normalized()
        var lines: [String] = [r.name]
        lines.append("Film Simulation: \(r.filmSimulation.label)")
        lines.append("Grain Effect: \(grainText(r.grain))")
        lines.append("Color Chrome Effect: \(r.colorChrome.rawValue.capitalized)")
        lines.append("Color Chrome FX Blue: \(r.colorChromeBlue.rawValue.capitalized)")
        if r.smoothSkin != .off { lines.append("Smooth Skin Effect: \(r.smoothSkin.rawValue.capitalized)") }
        let wbName = r.whiteBalance == .kelvin ? "\(r.kelvin)K" : wbText(r.whiteBalance)
        lines.append("White Balance: \(wbName), \(signed(r.wbShiftRed)) Red & \(signed(r.wbShiftBlue)) Blue")
        lines.append("Dynamic Range: \(r.dynamicRange.label)")
        lines.append("Highlight: \(signed(r.highlight))")
        lines.append("Shadow: \(signed(r.shadow))")
        if r.filmSimulation.isMonochrome {
            if r.monoWarmCool != 0 || r.monoMagentaGreen != 0 {
                lines.append("Monochromatic Color: \(signed(r.monoWarmCool)) WC & \(signed(r.monoMagentaGreen)) MG")
            }
        } else {
            lines.append("Color: \(signed(r.color))")
        }
        lines.append("Sharpness: \(signed(r.sharpness))")
        lines.append("High ISO NR: \(signed(r.noiseReduction))")
        lines.append("Clarity: \(signed(r.clarity))")
        if !r.isoNote.isEmpty { lines.append("ISO: \(r.isoNote)") }
        if !r.exposureNote.isEmpty { lines.append("Exposure Compensation: \(r.exposureNote)") }
        if !r.source.isEmpty { lines.append("Source: \(r.source)") }
        if !r.notes.isEmpty { lines.append("Notes: \(r.notes)") }
        return lines.joined(separator: "\n")
    }

    /// Several recipes in one text file are separated by a line of `---`. Export uses the same separator.
    public static let separator = "\n---\n"

    public static func splitBlocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.count >= 3, t.allSatisfy({ $0 == "-" || $0 == "=" }) {
                blocks.append(current.joined(separator: "\n")); current = []
            } else {
                current.append(line)
            }
        }
        blocks.append(current.joined(separator: "\n"))
        return blocks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: helpers

    static func normalizeKey(_ k: String) -> String {
        k.lowercased().filter { $0.isLetter }
    }

    static func filmSimulation(_ v: String) -> FilmSimulation? {
        let s = v.filter { $0.isLetter || $0 == "+" }
        let filter: String? = {
            if s.contains("+ye") || s.hasSuffix("ye") || s.contains("yellow") { return "y" }
            if s.contains("+r") || s.contains("red") || s.hasSuffix("r") && (s.hasPrefix("acros") || s.hasPrefix("mono")) { return "r" }
            if s.contains("+g") || s.contains("green") || s.hasSuffix("g") && (s.hasPrefix("acros") || s.hasPrefix("mono")) { return "g" }
            return nil
        }()
        if s.contains("bleach") { return .eternaBleachBypass }
        if s.contains("eterna") || s.contains("cinema") { return .eterna }
        if s.contains("classicneg") || s.contains("classicnegative") { return .classicNeg }
        if s.contains("classicchrome") { return .classicChrome }
        if s.contains("nostalgic") { return .nostalgicNeg }
        if s.contains("reala") { return .realaAce }
        if s.contains("pronegstd") || s.contains("pronegstandard") { return .proNegStd }
        if s.contains("proneghi") { return .proNegHi }
        if s.contains("velvia") || s.contains("vivid") { return .velvia }
        if s.contains("astia") || s.contains("soft") { return .astia }
        if s.contains("provia") || s.contains("standard") { return .provia }
        if s.contains("sepia") { return .sepia }
        if s.contains("acros") {
            switch filter ?? "" { case "y": return .acrosYellow; case "r": return .acrosRed; case "g": return .acrosGreen; default: return .acros }
        }
        if s.contains("mono") || s.contains("bw") || s.contains("blackandwhite") {
            switch filter ?? "" { case "y": return .monochromeYellow; case "r": return .monochromeRed; case "g": return .monochromeGreen; default: return .monochrome }
        }
        return nil
    }

    static func effect(_ v: String) -> EffectStrength? {
        if v.contains("strong") { return .strong }
        if v.contains("weak") { return .weak }
        if v.contains("off") || v.contains("none") || v == "0" { return .off }
        return nil
    }

    static func grain(_ v: String) -> GrainEffect? {
        guard let strength = effect(v) else { return nil }
        let large = v.contains("large")
        switch strength {
        case .off: return .off
        case .weak: return large ? .weakLarge : .weakSmall
        case .strong: return large ? .strongLarge : .strongSmall
        }
    }

    static func dynamicRange(_ v: String) -> DynamicRange? {
        if v.contains("auto") { return .auto }
        if v.contains("400") { return .dr400 }
        if v.contains("200") { return .dr200 }
        if v.contains("100") { return .dr100 }
        return nil
    }

    static func whiteBalance(_ v: String, into r: inout Recipe) -> Bool {
        let parts = v.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let mode = parts.first else { return false }
        var matched = true
        if let k = firstInt(in: mode), mode.contains("k"), k >= 2500 {
            r.whiteBalance = .kelvin; r.kelvin = k
        } else if mode.contains("ambience") { r.whiteBalance = .autoAmbiencePriority }
        else if mode.contains("white priority") || mode.contains("white-priority") { r.whiteBalance = .autoWhitePriority }
        else if mode.contains("auto") { r.whiteBalance = .auto }
        else if mode.contains("daylight") || mode.contains("fine") || mode.contains("sunny") { r.whiteBalance = .daylight }
        else if mode.contains("shade") { r.whiteBalance = .shade }
        else if mode.contains("fluorescent") {
            r.whiteBalance = mode.contains("3") ? .fluorescent3 : mode.contains("2") ? .fluorescent2 : .fluorescent1
        }
        else if mode.contains("incandescent") || mode.contains("tungsten") { r.whiteBalance = .incandescent }
        else if mode.contains("underwater") { r.whiteBalance = .underwater }
        else { matched = false }

        let shift = parts.count > 1 ? parts[1] : (matched ? "" : v)
        if let red = signedNumber(before: ["red", "r"], in: shift) { r.wbShiftRed = Int(red) }
        if let blue = signedNumber(before: ["blue", "b"], in: shift) { r.wbShiftBlue = Int(blue) }
        return matched
    }

    static func toneCurve(_ v: String) -> (h: Double?, s: Double?) {
        let h = signedNumber(after: "h", in: v) ?? signedNumber(before: ["h", "highlight"], in: v)
        let s = signedNumber(after: "s", in: v) ?? signedNumber(before: ["s", "shadow"], in: v)
        return (h, s)
    }

    /// Parses "+1", "-0.5", "0", "+1.5 (…)", "-1/2", "+2 1/2". Ignores trailing text.
    static func number(_ v: String) -> Double? {
        let scanner = Scanner(string: v.replacingOccurrences(of: "½", with: " 1/2"))
        scanner.charactersToBeSkipped = .whitespaces
        var sign = 1.0
        if scanner.scanString("+") != nil { sign = 1 } else if scanner.scanString("-") != nil || scanner.scanString("−") != nil { sign = -1 }
        guard let whole = scanner.scanDouble() else { return nil }
        var value = whole
        if scanner.scanString("/") != nil, let den = scanner.scanDouble(), den != 0 {
            value = whole / den
        } else if let num = scanner.scanDouble(), scanner.scanString("/") != nil, let den = scanner.scanDouble(), den != 0 {
            value = whole + num / den
        }
        return sign * value
    }

    /// Finds a signed number followed by one of `labels`, e.g. "+2 Red" or "-4 B".
    static func signedNumber(before labels: [String], in v: String) -> Double? {
        let tokens = v.replacingOccurrences(of: "&", with: " ").split(whereSeparator: { $0 == " " || $0 == "," })
        for (i, t) in tokens.enumerated() {
            // "+2red" glued form
            for label in labels {
                if t.hasSuffix(label), let n = number(String(t.dropLast(label.count))) { return n }
                if i + 1 < tokens.count, tokens[i + 1].hasPrefix(label), let n = number(String(t)) {
                    // only accept exact single-letter labels when the next token is exactly that letter
                    if label.count == 1 && tokens[i + 1].count != 1 { continue }
                    return n
                }
            }
        }
        return nil
    }

    /// Finds a number right after a label, e.g. "H+1" or "S -0.5".
    static func signedNumber(after label: String, in v: String) -> Double? {
        let compact = v.replacingOccurrences(of: " ", with: "")
        guard let range = compact.range(of: label) else { return nil }
        return number(String(compact[range.upperBound...]))
    }

    static func firstInt(in v: String) -> Int? {
        let digits = v.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return Int(digits)
    }

    static func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }
    static func signed(_ v: Double) -> String {
        let s = v == v.rounded() ? String(Int(v)) : String(v)
        return v > 0 ? "+\(s)" : s
    }

    static func grainText(_ g: GrainEffect) -> String {
        switch g {
        case .off: return "Off"
        case .weakSmall: return "Weak, Small"
        case .strongSmall: return "Strong, Small"
        case .weakLarge: return "Weak, Large"
        case .strongLarge: return "Strong, Large"
        }
    }

    static func wbText(_ w: WhiteBalance) -> String {
        switch w {
        case .auto: return "Auto"
        case .autoWhitePriority: return "Auto White Priority"
        case .autoAmbiencePriority: return "Auto Ambience Priority"
        case .kelvin: return "Kelvin"
        case .daylight: return "Daylight"
        case .shade: return "Shade"
        case .fluorescent1: return "Fluorescent 1"
        case .fluorescent2: return "Fluorescent 2"
        case .fluorescent3: return "Fluorescent 3"
        case .incandescent: return "Incandescent"
        case .underwater: return "Underwater"
        }
    }
}

/// The app's own export format: a JSON bundle of recipes.
public struct RecipeBundle: Codable, Sendable {
    public static let formatID = "fx-companion.recipes"
    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var recipes: [Recipe]

    public init(recipes: [Recipe]) {
        self.format = Self.formatID
        self.version = 1
        self.exportedAt = Date()
        self.recipes = recipes
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    /// Accepts a bundle, a single recipe JSON, or plain text.
    public static func importAny(_ data: Data, fallbackName: String = "imported") -> [Recipe] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let b = try? d.decode(RecipeBundle.self, from: data), b.format == formatID {
            return b.recipes.map { $0.normalized() }
        }
        if let one = try? d.decode(Recipe.self, from: data), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
            return [one.normalized()]
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return RecipeText.splitBlocks(text).map { RecipeText.parse($0, fallbackName: fallbackName).recipe }
    }
}

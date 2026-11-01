import Foundation
import Observation
import FujiKit
import UniformTypeIdentifiers
import CoreTransferable

/// The recipe library, persisted as a JSON bundle in Application Support.
@MainActor
@Observable
final class RecipeStore {
    private(set) var recipes: [Recipe] = []
    var lastError: String?
    /// What C1–C7 held at the last USB read. Kept on disk so the marks survive unplugging.
    private(set) var camera: CameraSnapshot?

    private let url: URL
    private let cameraURL: URL

    struct CameraSnapshot: Codable, Equatable {
        struct Slot: Codable, Equatable {
            var slot: Int
            var name: String
            var recipe: Recipe
        }
        var slots: [Slot]
        var readAt: Date
    }

    init(filename: String = "recipes.json") {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent(filename)
        cameraURL = dir.appendingPathComponent("camera-slots.json")
        load()
        if recipes.isEmpty { recipes = Self.starters }
        camera = (try? Data(contentsOf: cameraURL)).flatMap { try? Self.decoder.decode(CameraSnapshot.self, from: $0) }
    }

    // MARK: Camera marks

    /// Records a fresh read of the camera's slots. An empty read (cable out) keeps the last one.
    func updateCamera(_ presets: [CameraPreset]) {
        guard !presets.isEmpty else { return }
        var slots = camera?.slots ?? []
        for p in presets {
            let s = CameraSnapshot.Slot(slot: p.slot, name: p.name, recipe: PresetCodec.decode(p))
            if let i = slots.firstIndex(where: { $0.slot == p.slot }) { slots[i] = s } else { slots.append(s) }
        }
        slots.sort { $0.slot < $1.slot }
        let snap = CameraSnapshot(slots: slots, readAt: Date())
        guard snap.slots != camera?.slots || camera == nil else { camera?.readAt = snap.readAt; return }
        camera = snap
        if let data = try? Self.encoder.encode(snap) { try? data.write(to: cameraURL, options: .atomic) }
    }

    /// Slots whose settings match this recipe at the last read. Names are ignored: the camera
    /// may hold a shorter or upper-cased name.
    func slots(for r: Recipe) -> [Int] {
        guard let camera else { return [] }
        let key = r.settingsKey
        return camera.slots.filter { $0.recipe.settingsKey == key }.map(\.slot)
    }

    /// The library recipe a slot matches, preferring the same name.
    func libraryMatch(for slot: Recipe) -> Recipe? {
        let same = recipes.filter { $0.sameSettings(as: slot) }
        return same.first { $0.nameKey == slot.nameKey } ?? same.first
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    var sorted: [Recipe] { recipes.sorted { $0.updatedAt > $1.updatedAt } }

    func recipe(_ id: Recipe.ID) -> Recipe? { recipes.first { $0.id == id } }

    func upsert(_ r: Recipe) {
        var r = r.normalized()
        r.updatedAt = Date()
        if let i = recipes.firstIndex(where: { $0.id == r.id }) { recipes[i] = r } else { recipes.append(r) }
        save()
    }

    func delete(_ ids: [Recipe.ID]) {
        recipes.removeAll { ids.contains($0.id) }
        save()
    }

    func duplicate(_ r: Recipe) -> Recipe {
        var copy = r
        copy.id = UUID()
        copy.name = String((r.name + " copy").prefix(Recipe.maxNameLength))
        copy.createdAt = Date()
        upsert(copy)
        return copy
    }

    struct ImportResult: Equatable {
        var added = 0
        var updated = 0
        var skipped = 0
    }

    /// Imports recipes idempotently: importing the same thing twice changes nothing.
    /// - Same id as a library recipe: updated if the incoming copy is newer, otherwise skipped.
    /// - Same name (any case or spacing) and same camera settings: skipped; empty notes are filled in.
    /// - Anything else is added. Same name with different settings is a different recipe and is kept.
    @discardableResult
    func importData(_ data: Data, fallbackName: String) -> ImportResult {
        var result = ImportResult()
        for var r in RecipeBundle.importAny(data, fallbackName: fallbackName) {
            r = r.normalized()
            if let i = recipes.firstIndex(where: { $0.id == r.id }) {
                if r.updatedAt > recipes[i].updatedAt, r != recipes[i] { recipes[i] = r; result.updated += 1 } else { result.skipped += 1 }
                continue
            }
            if let i = recipes.firstIndex(where: { $0.isDuplicate(of: r) }) {
                if fillNotes(&recipes[i], from: r) { result.updated += 1 } else { result.skipped += 1 }
                continue
            }
            recipes.append(r)
            result.added += 1
        }
        if result.added + result.updated > 0 { save() }
        AppLog.write(.recipes, "import \(fallbackName): +\(result.added) ~\(result.updated) =\(result.skipped)")
        return result
    }

    /// Saves a recipe read from a camera slot. One set of settings gives one recipe: if the
    /// library already has these settings under any name, nothing is added and that recipe is returned.
    func saveFromCamera(_ r: Recipe) -> (recipe: Recipe, added: Bool) {
        if let existing = libraryMatch(for: r) { return (existing, false) }
        var copy = r.normalized()
        copy.id = UUID()
        copy.createdAt = Date(); copy.updatedAt = Date()
        recipes.append(copy)
        save()
        AppLog.write(.recipes, "saved \(copy.name) from camera")
        return (copy, true)
    }

    /// Saves every slot whose settings aren't in the library yet. Empty or unnamed slots are
    /// saved under "C<n>". Returns how many were added and how many were already there.
    func saveAllFromCamera(_ presets: [CameraPreset]) -> (added: Int, already: Int) {
        var added = 0, already = 0
        for p in presets.sorted(by: { $0.slot < $1.slot }) {
            if saveFromCamera(PresetCodec.decode(p)).added { added += 1 } else { already += 1 }
        }
        AppLog.write(.recipes, "pulled from camera: +\(added) =\(already)")
        return (added, already)
    }

    /// Copies notes the library recipe is missing. Returns true if anything changed.
    private func fillNotes(_ target: inout Recipe, from r: Recipe) -> Bool {
        var changed = false
        func fill(_ k: WritableKeyPath<Recipe, String>) {
            if target[keyPath: k].isEmpty, !r[keyPath: k].isEmpty { target[keyPath: k] = r[keyPath: k]; changed = true }
        }
        fill(\.isoNote); fill(\.exposureNote); fill(\.notes); fill(\.source)
        let newTags = r.tags.filter { !target.tags.contains($0) }
        if !newTags.isEmpty { target.tags += newTags; changed = true }
        return changed
    }

    /// Folds exact duplicates already in the library (same name and settings) into the newest copy.
    private func collapseDuplicates() -> Int {
        var kept: [Recipe] = []
        var removed = 0
        for r in recipes.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if let i = kept.firstIndex(where: { $0.isDuplicate(of: r) }) {
                _ = fillNotes(&kept[i], from: r)
                removed += 1
            } else {
                kept.append(r)
            }
        }
        if removed > 0 {
            let order = recipes.map(\.id)
            recipes = kept.sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        }
        return removed
    }

    func exportBundle(_ subset: [Recipe]? = nil) -> Data {
        (try? RecipeBundle(recipes: subset ?? sorted).encoded()) ?? Data()
    }

    func exportText(_ subset: [Recipe]? = nil) -> String {
        (subset ?? sorted).map(RecipeText.format).joined(separator: RecipeText.separator)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        recipes = RecipeBundle.importAny(data)
        let removed = collapseDuplicates()
        if removed > 0 {
            AppLog.write(.recipes, "merged \(removed) duplicate recipe\(removed == 1 ? "" : "s")")
            save()
        }
    }

    private func save() {
        do {
            try RecipeBundle(recipes: recipes).encoded().write(to: url, options: .atomic)
            lastError = nil
        } catch {
            lastError = "couldn't save the library: \(error.localizedDescription)"
        }
    }

    /// A few well-known starting points so the library isn't empty on first launch.
    static let starters: [Recipe] = {
        let texts = [
            """
            Kodachrome 64
            Film Simulation: Classic Chrome
            Grain Effect: Weak, Small
            Color Chrome Effect: Strong
            Color Chrome FX Blue: Weak
            White Balance: Daylight, +2 Red & -5 Blue
            Dynamic Range: DR200
            Highlight: 0
            Shadow: +0.5
            Color: +2
            Sharpness: +1
            High ISO NR: -4
            Clarity: +3
            ISO: Auto, up to ISO 6400
            Exposure Compensation: 0 to +1/3
            """,
            """
            Classic Negative
            Film Simulation: Classic Negative
            Grain Effect: Weak, Large
            Color Chrome Effect: Strong
            Color Chrome FX Blue: Off
            White Balance: Auto, +1 Red & -2 Blue
            Dynamic Range: DR400
            Highlight: -1
            Shadow: +1
            Color: +2
            Sharpness: -2
            High ISO NR: -4
            Clarity: -2
            ISO: Auto, up to ISO 6400
            Exposure Compensation: +1/3 to +2/3
            """,
            """
            Acros Push
            Film Simulation: Acros+R
            Grain Effect: Strong, Large
            Color Chrome Effect: Off
            White Balance: Auto, 0 Red & 0 Blue
            Dynamic Range: DR200
            Highlight: +1
            Shadow: +2
            Monochromatic Color: +2 WC & 0 MG
            Sharpness: +1
            High ISO NR: -4
            Clarity: +2
            ISO: Auto, up to ISO 12800
            Exposure Compensation: -1/3 to +1/3
            """,
        ]
        return texts.map { t in
            var r = RecipeText.parse(t).recipe
            r.source = "starter"
            return r
        }
    }()
}

/// Share sheet payloads.
struct RecipeBundleFile: Transferable {
    var data: Data
    var name: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName { $0.name }
    }
}

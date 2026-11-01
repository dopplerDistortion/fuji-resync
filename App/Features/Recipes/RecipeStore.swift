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

    private let url: URL

    init(filename: String = "recipes.json") {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent(filename)
        load()
        if recipes.isEmpty { recipes = Self.starters }
    }

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

    /// Imports recipes, skipping any whose settings already exist under the same name. Returns how many were added.
    @discardableResult
    func importData(_ data: Data, fallbackName: String) -> Int {
        let incoming = RecipeBundle.importAny(data, fallbackName: fallbackName)
        var added = 0
        for var r in incoming {
            if recipes.contains(where: { $0.name == r.name && $0.sameSettings(as: r) }) { continue }
            if recipes.contains(where: { $0.id == r.id }) { r.id = UUID() }
            recipes.append(r.normalized())
            added += 1
        }
        save()
        return added
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

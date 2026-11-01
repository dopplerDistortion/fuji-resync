import UIKit
import SwiftUI
import FujiKit
import UniformTypeIdentifiers

/// A library row, marked with the camera slots that hold it.
struct RecipeRow: View {
    var recipe: Recipe
    var slots: [Int]

    var body: some View {
        LeaderRow(mark: slots.isEmpty ? ">" : "■",
                  label: recipe.name.lowercased(),
                  value: slots.isEmpty ? recipe.filmSimulation.label.lowercased()
                                       : slots.map { "c\($0)" }.joined(separator: " ") + " · " + recipe.filmSimulation.label.lowercased(),
                  valueColor: slots.isEmpty ? Token.mutedForeground : Token.foreground)
    }
}

struct RecipeListView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(USBCameraController.self) private var usb
    @State private var query = ""
    @State private var importing = false
    @State private var notice: String?
    @State private var pasteRecipe: Recipe?

    private var filtered: [Recipe] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.sorted }
        return store.sorted.filter {
            $0.name.lowercased().contains(q) || $0.filmSimulation.label.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        Screen(path: ["recipes"], title: "recipes", subtitle: "your film simulation recipes. edit here, send to C1–C7 over usb.") {
            HStack(spacing: 8) {
                NavigationLink(value: Route.newRecipe) { Text("new") }.buttonStyle(.fx(.default, compact: true))
                Button("import") { importing = true }.buttonStyle(.fx(.secondary, compact: true))
                Button("paste") { pasteFromClipboard() }.buttonStyle(.fx(.secondary, compact: true))
                if usb.isReady {
                    Button("pull") { Task { notice = PullNote.text(await usb.pull(into: store)) } }
                        .buttonStyle(.fx(.secondary, compact: true))
                        .disabled(usb.busy != nil)
                }
                Spacer()
                Menu {
                    ShareLink(item: RecipeBundleFile(data: store.exportBundle(), name: "recipes.json"),
                              preview: SharePreview("recipes.json")) { Text("export json") }
                    ShareLink(item: store.exportText()) { Text("export text") }
                } label: { Text("export").font(Typeface.medium(13)).foregroundStyle(Token.foreground) }
            }

            FXTextField(label: "grep", text: $query, prompt: "name, simulation or tag")

            if let notice {
                Text(notice).font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
            }
            if let err = store.lastError {
                FaultPanel(title: "save", message: err)
            }

            VStack(alignment: .leading, spacing: 10) {
                ListingHeader(path: "/recipes", count: filtered.count)
                if let cam = store.camera {
                    Text("■ c1–c7 = on the camera at the last usb read, \(cam.readAt.formatted(date: .abbreviated, time: .shortened).lowercased()).")
                        .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
                } else {
                    Text("> connect the camera over usb once to see which recipes are on it.")
                        .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
                }
                if filtered.isEmpty {
                    Text("> nothing matches. clear the search or import a file.")
                        .font(Typeface.body(14)).foregroundStyle(Token.mutedForeground)
                }
                ForEach(filtered) { r in
                    NavigationLink(value: Route.recipe(r.id)) {
                        RecipeRow(recipe: r, slots: store.slots(for: r))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("duplicate") { _ = store.duplicate(r) }
                        ShareLink(item: RecipeText.format(r)) { Text("share as text") }
                        Button("delete", role: .destructive) { store.delete([r.id]) }
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .text], allowsMultipleSelection: true) { result in
            handleImport(result)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            var total = RecipeStore.ImportResult()
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    let r = store.importData(data, fallbackName: url.deletingPathExtension().lastPathComponent)
                    total.added += r.added; total.updated += r.updated; total.skipped += r.skipped
                }
            }
            notice = Self.describe(total, verb: "imported")
        case let .failure(e):
            notice = "> import failed: \(e.localizedDescription)"
        }
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            notice = "> clipboard is empty. copy a recipe's text first."
            return
        }
        notice = Self.describe(store.importData(Data(text.utf8), fallbackName: "pasted"), verb: "pasted")
    }

    static func describe(_ r: RecipeStore.ImportResult, verb: String) -> String {
        func n(_ c: Int) -> String { "\(c) recipe\(c == 1 ? "" : "s")" }
        var parts: [String] = []
        if r.added > 0 { parts.append("\(verb) \(n(r.added))") }
        if r.updated > 0 { parts.append("updated \(n(r.updated))") }
        if r.skipped > 0 { parts.append("\(r.skipped) already here") }
        return parts.isEmpty ? "> nothing to import." : "> " + parts.joined(separator: ", ") + "."
    }
}

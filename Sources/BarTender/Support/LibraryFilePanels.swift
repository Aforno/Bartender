import AppKit
import UniformTypeIdentifiers

/// AppKit file and confirmation panels used by library transfer. Kept off
/// `AppModel` so generation and persistence can be tested without modal UI.
enum LibraryFilePanels {
    static func chooseExportURL() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Bar Tender Library"
        panel.nameFieldStringValue = "BarTender-Library.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func chooseImportURL() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Bar Tender Library"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func confirmImport() -> AppletImportMode? {
        let choice = NSAlert()
        choice.messageText = "Import this tool library?"
        choice.informativeText = """
        Merge keeps tools with different IDs and updates matching IDs. Replace removes the current library first. Imported generated code always requires fresh approval. HTTP, port, git, metrics, and timer tools start running immediately after import; unapproved shell commands stay inert.
        """
        choice.addButton(withTitle: "Merge")
        choice.addButton(withTitle: "Replace All")
        choice.addButton(withTitle: "Cancel")
        let response = choice.runModal()
        guard response != .alertThirdButtonReturn else { return nil }
        return response == .alertSecondButtonReturn ? .replace : .merge
    }

    static func chooseDiagnosticsURL() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Sanitized Diagnostics"
        panel.nameFieldStringValue = "BarTender-Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func confirmDelete(name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete “\(name)”?"
        alert.informativeText = "This removes the applet from your library. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}

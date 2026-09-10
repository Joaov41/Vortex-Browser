import WebKit

/// Replace only this feature's document-start script, retaining all other scripts and their order.
/// WebKit has no single-user-script removal API, so rebuilding the list must preserve its peers.
@MainActor
enum ManagedUserScript {
    /// WebKit retains web-extension scripts when removing the app's scripts.
    /// Re-adding those same objects duplicates the extension on every update.
    static func replaceAppScripts(_ scripts: [WKUserScript], in controller: WKUserContentController) {
        controller.removeAllUserScripts()
        var installed = Set(controller.userScripts.map(ObjectIdentifier.init))
        for script in scripts where installed.insert(ObjectIdentifier(script)).inserted {
            controller.addUserScript(script)
        }
    }

    @discardableResult
    static func install(source: String, identifier: String, in controller: WKUserContentController) -> Bool {
        let marker = "// Vortex managed script: \(identifier)\n"
        let taggedSource = marker + source
        let scripts = controller.userScripts
        let owned = scripts.filter { $0.source.hasPrefix(marker) }
        if owned.count == 1, owned[0].source == taggedSource { return false }

        let replacement = WKUserScript(source: taggedSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        var updated: [WKUserScript] = []
        var inserted = false
        for script in scripts {
            if script.source.hasPrefix(marker) {
                if !inserted { updated.append(replacement); inserted = true }
            } else {
                updated.append(script)
            }
        }
        if !inserted { updated.append(replacement) }
        replaceAppScripts(updated, in: controller)
        return true
    }
}

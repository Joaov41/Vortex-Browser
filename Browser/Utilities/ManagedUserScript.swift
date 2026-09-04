import WebKit

/// Replace only this feature's document-start script, retaining all other scripts and their order.
/// WebKit has no single-user-script removal API, so rebuilding the list must preserve its peers.
@MainActor
enum ManagedUserScript {
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
        controller.removeAllUserScripts()
        updated.forEach(controller.addUserScript)
        return true
    }
}

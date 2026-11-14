// Amethyst's JIT helper: a classic app extension that runs StikJIT in a second
// process, because a process cannot synchronously debug itself.
//
// The host (Natives/JITManager.m) starts this bundle from PlugIns by its bundle
// identifier, sends it one JSON request as an extension item, and waits for the
// JSON response. StikJIT itself is not a separate framework here: its sources
// are compiled into this executable together with this file by the Makefile
// (Natives/jit/../external/StikJIT), so the helper always matches the Swift
// compiler that built the rest of the app.

import Foundation

private enum HelperMessage {
    static let requestItemKey = "amethyst-jit-request"
    static let responseItemKey = "amethyst-jit-response"
}

private struct HelperRequest: Codable {
    let operation: String
    let targetPID: Int32?
    let pairingBase64: String?
    let scriptBase64: String?
}

private struct HelperResponse: Codable {
    let success: Bool
    let message: String
    let txmPresent: Bool?
}

private enum HelperWork {
    /// One request at a time. An enable request holds this queue for as long as the
    /// debugger is attached, which is the whole time the host is preparing its JIT pool.
    static let queue = DispatchQueue(label: "org.angelauramc.amethyst.jit-helper")

    static var root: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
    }

    static func handle(_ request: HelperRequest) -> HelperResponse {
        let manager = FileManager.default
        let paths = DDIPaths.default(in: root)

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)

            if request.operation == "resetDDI" {
                try StikJIT.resetCachedDDI(at: paths)
                return HelperResponse(success: true,
                                      message: "Developer Disk Image cache reset.",
                                      txmPresent: StikJIT.isTXMPresent)
            }

            guard let pairingData = request.pairingBase64.flatMap({ Data(base64Encoded: $0) }),
                  !pairingData.isEmpty else {
                throw NSError(domain: "AmethystJITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The pairing file was not provided."])
            }
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            switch request.operation {
            case "prepare":
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL,
                    paths: paths,
                    progress: { NSLog("[AmethystJIT] prepare: %@", String(describing: $0)) })
                switch readiness {
                case .ready(let security):
                    return HelperResponse(success: true,
                                          message: "The device is reachable and the Developer Disk Image is ready.",
                                          txmPresent: security.isTXMPresent)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return HelperResponse(success: false, message: reason, txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return HelperResponse(success: false,
                                          message: "StikJIT returned an unknown preparation state.",
                                          txmPresent: StikJIT.isTXMPresent)
                }

            case "enable":
                guard let targetPID = request.targetPID,
                      let scriptBase64 = request.scriptBase64,
                      let scriptData = Data(base64Encoded: scriptBase64),
                      let script = String(data: scriptData, encoding: .utf8),
                      !script.isEmpty else {
                    throw NSError(domain: "AmethystJITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The target process or the JIT script was not provided."])
                }
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    script: .customBase64(scriptBase64),
                    forceScript: true,
                    preparationProgress: { NSLog("[AmethystJIT] prepare: %@", String(describing: $0)) },
                    progress: { NSLog("[AmethystJIT] %@", $0) })
                _ = script
                return HelperResponse(success: true,
                                      message: "The debugger detached cleanly from Amethyst.",
                                      txmPresent: StikJIT.isTXMPresent)

            default:
                throw NSError(domain: "AmethystJITHelper", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Unknown JIT helper operation \(request.operation)."])
            }
        } catch {
            return HelperResponse(success: false,
                                  message: error.localizedDescription,
                                  txmPresent: StikJIT.isTXMPresent)
        }
    }
}

/// NSExtensionPrincipalClass in Info.plist. The request is JSON in the first input
/// item's userInfo; the response is JSON in the item the request completes with.
/// An enable request completes only once Amethyst's script detaches, so this process
/// stays alive while the debugger services the JIT breakpoints.
@objc(AmethystJITHelperHandler)
final class AmethystJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[HelperMessage.requestItemKey] as? Data
        let request = data.flatMap { try? JSONDecoder().decode(HelperRequest.self, from: $0) }

        HelperWork.queue.async {
            let response: HelperResponse
            if let request {
                response = HelperWork.handle(request)
            } else {
                response = HelperResponse(success: false,
                                          message: "Amethyst's JIT helper received no request.",
                                          txmPresent: nil)
            }

            let item = NSExtensionItem()
            item.userInfo = [
                HelperMessage.responseItemKey:
                    (try? JSONEncoder().encode(response)) ?? Data(),
            ]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}

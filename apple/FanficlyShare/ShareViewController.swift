import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.view.backgroundColor = .clear
        
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            self.cancelRequest()
            return
        }
        
        var urlFound = false
        
        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    urlFound = true
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] (item, error) in
                        let url = item as? URL
                        Task { @MainActor in
                            guard let self = self else { return }
                            if let url = url {
                                self.openMainApp(with: url)
                            } else {
                                self.cancelRequest()
                            }
                        }
                    }
                    break
                }
            }
            if urlFound { break }
        }
        
        if !urlFound {
            self.cancelRequest()
        }
    }
    
    private func openMainApp(with sharedURL: URL) {
        let scheme = "fanficly://import?url="
        guard let encodedURL = sharedURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let appURL = URL(string: "\(scheme)\(encodedURL)") else {
            self.cancelRequest()
            return
        }
        
        // Bypassing Safari Share Extension url opening restrictions via dynamic UIApplication retrieval
        if let applicationClass = NSClassFromString("UIApplication") as? NSObject.Type,
           let sharedApplication = applicationClass.perform(#selector(getter: ShareExtensionUIApplicationBypass.sharedApplication))?.takeUnretainedValue() as? NSObject {
            let selector = #selector(ShareExtensionUIApplicationBypass.openURL(_:options:completionHandler:))
            typealias OpenURLMethod = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
            
            let method = unsafeBitCast(sharedApplication.method(for: selector), to: OpenURLMethod.self)
            let completion: @convention(block) (Bool) -> Void = { [weak self] success in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                }
            }
            method(sharedApplication, selector, appURL as NSURL, [:] as NSDictionary, completion)
        } else {
            // Fallback to standard context opening
            self.extensionContext?.open(appURL, completionHandler: { [weak self] success in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                }
            })
        }
    }
    
    private func cancelRequest() {
        self.extensionContext?.cancelRequest(withError: NSError(domain: "FanficlyShare", code: 1, userInfo: [NSLocalizedDescriptionKey: "No URL found"]))
    }
}

@objc protocol ShareExtensionUIApplicationBypass {
    var sharedApplication: AnyObject? { get }
    func openURL(_ url: URL, options: [String: Any], completionHandler: ((Bool) -> Void)?)
}

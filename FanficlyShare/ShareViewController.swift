import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
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
                        guard let self = self else { return }
                        if let url = item as? URL {
                            self.openMainApp(with: url)
                        } else {
                            self.cancelRequest()
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
        
        // Use extensionContext to open URL
        self.extensionContext?.open(appURL, completionHandler: { [weak self] success in
            guard let self = self else { return }
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        })
    }
    
    private func cancelRequest() {
        self.extensionContext?.cancelRequest(withError: NSError(domain: "FanficlyShare", code: 1, userInfo: [NSLocalizedDescriptionKey: "No URL found"]))
    }
}

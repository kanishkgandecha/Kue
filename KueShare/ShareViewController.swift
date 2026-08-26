//
//  ShareViewController.swift
//  KueShare
//
//  The extension's actual entry point (`NSExtensionPrincipalClass` in Info.plist — no
//  storyboard). Its only job is to gather this share's `NSItemProvider`s and the real,
//  live dependencies, then hand off to `ShareExtensionRootView` (SwiftUI) for everything
//  else — see that file's header for the actual flow.
//

import UIKit
import SwiftUI
import SwiftData

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let providers: [ShareItemProviding] = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        let root = ShareExtensionRootView(
            providers: providers,
            parser: FoundationModelsParser(),
            availabilityChecker: SystemAIAvailabilityChecker(),
            container: ModelContainerFactory.makeDefaultOrNil(),
            onFinish: { [weak self] in
                // docs (Phase 10) requirement 7: cancellation and successful creation both
                // end the extension the same way — nothing partial was ever written either
                // way, so there's nothing for the host app to distinguish.
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        )

        let hosting = UIHostingController(rootView: root)
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
    }
}

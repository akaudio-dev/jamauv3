//
//  ViewControllerRepresentable.swift
//  jamauv3
//
//  Created by Andrei Kozlov on 1/16/26.
//

import SwiftUI

#if os(iOS) || os(visionOS)

struct AUViewControllerUI: UIViewControllerRepresentable {
    var auViewController: UIViewController?

    init(viewController: UIViewController?) {
        self.auViewController = viewController
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        guard let auViewController = self.auViewController else {
            return UIViewController()
        }

        let viewController = UIViewController()
        viewController.addChild(auViewController)

        auViewController.view.translatesAutoresizingMaskIntoConstraints = false
        viewController.view.addSubview(auViewController.view)
        NSLayoutConstraint.activate([
            auViewController.view.topAnchor.constraint(equalTo: viewController.view.topAnchor),
            auViewController.view.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor),
            auViewController.view.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
            auViewController.view.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
        ])

        auViewController.didMove(toParent: viewController)
        return viewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
    }
}
#elseif os(macOS)
struct AUViewControllerUI: NSViewControllerRepresentable {
    
    var auViewController: NSViewController?

    init(viewController: NSViewController?) {
        self.auViewController = viewController
    }
    
    func makeNSViewController(context: Context) -> NSViewController {
        return self.auViewController!
    }
    
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        // No opp
    }
}
#endif

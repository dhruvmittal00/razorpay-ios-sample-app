//
//  SceneDelegate.swift
//  DuitNow Pay A2A Test App
//
//  Handles deep link callbacks from CIMB UAT app
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let _ = (scene as? UIWindowScene) else { return }

        // Handle deep link if app was launched via URL
        if let urlContext = connectionOptions.urlContexts.first {
            // Delay slightly so ViewController has finished loading
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.handleIncomingURL(urlContext.url)
            }
        }
    }

    // Handle deep link when app is already running
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        handleIncomingURL(url)
    }

    private func handleIncomingURL(_ url: URL) {
        print(">>> Deep link received: \(url.absoluteString)")

        guard url.scheme == "rzpcurlectestapp" else { return }

        // Try direct VC access first
        var handled = false
        if let rootVC = window?.rootViewController as? ViewController {
            rootVC.handleDeepLinkCallback(url: url)
            handled = true
        } else if let navVC = window?.rootViewController as? UINavigationController,
                  let vc = navVC.viewControllers.first as? ViewController {
            vc.handleDeepLinkCallback(url: url)
            handled = true
        }

        // Also post notification as fallback
        if !handled {
            NotificationCenter.default.post(
                name: ViewController.deepLinkNotification,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {}
    func sceneDidBecomeActive(_ scene: UIScene) {}
    func sceneWillResignActive(_ scene: UIScene) {}
    func sceneWillEnterForeground(_ scene: UIScene) {}
    func sceneDidEnterBackground(_ scene: UIScene) {}
}

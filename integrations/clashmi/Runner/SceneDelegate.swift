import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        var handled = false
        for context in URLContexts {
            if WLOCMainBridge.shared.handle(url: context.url) {
                handled = true
            }
        }
        if !handled {
            super.scene(scene, openURLContexts: URLContexts)
        }
    }
}

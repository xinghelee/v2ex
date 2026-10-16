import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        // 普通 iPhone 和折叠屏外屏保持竖屏；iPhone Duo 展开后的内屏接近方形且默认横置，
        // 只竖屏会被系统加黑边居中显示，所以大屏允许横屏铺满。
        guard let screen = window?.windowScene?.screen else { return .portrait }
        let shortSide = min(screen.bounds.width, screen.bounds.height)
        return shortSide >= 500 ? .allButUpsideDown : .portrait
    }
}

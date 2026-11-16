import AppKit
import Foundation

/// One-time guidance only; never reset system permissions.
@MainActor
final class HelperMigrationPresenter {
    static let shared = HelperMigrationPresenter()

    private static let shownDefaultsKey = "KeyStats.HelperMigrationShown"

    private init() {}

    func showIfNeeded(wasPreviouslyInstalled: Bool) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.shownDefaultsKey) else { return }
        // 立即置 true，防止任何路径再次触发（例如 alert 打开系统设置后 re-activate）
        defaults.set(true, forKey: Self.shownDefaultsKey)

        // Fresh install 没有任何旧 "KeyStats" TCC 条目可清理，再展示
        // "we cleared the old entry / last manual authorization" 文案会误导用户。
        // 常规权限 alert 会照常引导用户授权 KeytideHelper，无需此迁移引导。
        guard wasPreviouslyInstalled else { return }

        AppDelegate.trackEvent("helper_migration_prompt_shown")

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("helperMigration.title", comment: "")

        alert.informativeText = NSLocalizedString("helperMigration.authorizationOnly", comment: "")

        alert.addButton(withTitle: NSLocalizedString("helperMigration.openSettings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("helperMigration.later", comment: ""))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            AppDelegate.trackClick("helper_migration_open_settings")
            DispatchQueue.main.async { [weak self] in
                guard self != nil else { return }
                AppDelegate.shared?.requestAccessibilityPermission(analyticsSource: "migration_dialog")
            }
        } else {
            AppDelegate.trackClick("helper_migration_later")
        }
    }

}

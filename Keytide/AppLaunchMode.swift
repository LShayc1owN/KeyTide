import Foundation

/// Process-local opt-in. Release ignores the argument; no preference is persisted.
enum AppLaunchMode: Equatable {
    case normal
    case guiAcceptance

    static let current = AppLaunchMode(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        #if DEBUG
        self = arguments.dropFirst().contains("--debug-gui-acceptance") ? .guiAcceptance : .normal
        #else
        self = .normal
        #endif
    }

    /// Normal launches retain their existing compatibility behavior. Acceptance must
    /// stop before monitoring when the installed Helper reports a different protocol.
    func allowsHelperVersion(_ version: Int, expected: Int) -> Bool {
        self == .normal || version == expected
    }

    /// Preparing a public key must not enable the updater before release setup.
    func allowsUpdater(publicKey: String?, updatesEnabled: Bool) -> Bool {
        guard self == .normal, updatesEnabled, let publicKey,
              let bytes = Data(base64Encoded: publicKey) else { return false }
        return bytes.count == 32
    }
}

/// Copy the old application's domain once, before any singleton reads defaults.
/// Existing destination values win; daily snapshots are never added together.
enum ApplicationIdentityMigration {
    static let legacyDomain = "com.xuanlprk.KeyStatsMac"
    static let currentDomain = "com.xuanlprk.KeyTide"
    static let marker = "keytide.identityMigration.v1"

    static func migrate(defaults: UserDefaults, destination: String = currentDomain,
                        source: String = legacyDomain) {
        var current = defaults.persistentDomain(forName: destination) ?? [:]
        guard current[marker] as? Bool != true else { return }
        let previous = defaults.persistentDomain(forName: source) ?? [:]
        for (key, value) in previous where current[key] == nil {
            current[key] = value
        }
        current[marker] = true
        defaults.setPersistentDomain(current, forName: destination)
    }
}

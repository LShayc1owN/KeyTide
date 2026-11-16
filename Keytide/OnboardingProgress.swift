import Foundation

/// Separate from Analytics consent and installation tracking.
final class OnboardingProgress {
    enum Stage: String { case welcome, setup, completed, existing }
    static let key = "onboarding.state.v1"
    private let defaults: UserDefaults
    private(set) var stage: Stage

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let value = defaults.string(forKey: Self.key), let saved = Stage(rawValue: value) {
            stage = saved
        } else {
            let existing = ["dailyStats", "dailyStatsHistory", "launchAtLoginPrompted", "menuUIStyle.v1", "KeyStats.HelperMigrationShown"]
                .contains { defaults.object(forKey: $0) != nil }
            stage = existing ? .existing : .welcome
            defaults.set(stage.rawValue, forKey: Self.key)
        }
    }
    var shouldPresentAutomatically: Bool { stage == .welcome || stage == .setup }
    var usesWelcomeExperience: Bool { stage != .existing }
    func beginSetup() { save(.setup) }
    @discardableResult func complete(isMonitoring: Bool) -> Bool {
        guard isMonitoring else { return false }
        save(.completed)
        return true
    }
    private func save(_ stage: Stage) {
        self.stage = stage
        defaults.set(stage.rawValue, forKey: Self.key)
    }
}

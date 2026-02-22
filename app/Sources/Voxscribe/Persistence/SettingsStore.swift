import Foundation

actor SettingsStore {
    private let sessionStore: SessionStore

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    func load() async throws -> AppSettings {
        try await sessionStore.loadSettings()
    }

    func save(_ settings: AppSettings) async throws {
        try await sessionStore.saveSettings(settings)
    }
}

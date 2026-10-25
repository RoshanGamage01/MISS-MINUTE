import Combine
import Foundation

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings

    private let store: JSONFileStore<AppSettings>

    public init(store: JSONFileStore<AppSettings> = JSONFileStore(url: MinutesPaths.settingsURL)) {
        self.store = store
        self.settings = .default
    }

    public func load() async {
        do {
            settings = try await store.load(default: .default)
        } catch {
            settings = .default
        }
    }

    public func save() async {
        try? await store.save(settings)
    }

    public func update(_ mutate: (inout AppSettings) -> Void) async {
        mutate(&settings)
        await save()
    }
}

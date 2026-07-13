import Foundation

struct AppSettings: Codable {
    var fps: Int = 60
    var resolution: Int = 0
    var bitrate: Int = 0
    var timer: Int = 0
    var audioSource: Int = 0
}

extension AppSettings {
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "AppSettings")
        }
    }
    static func load() -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: "AppSettings"),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings
        }
        return AppSettings()
    }
}

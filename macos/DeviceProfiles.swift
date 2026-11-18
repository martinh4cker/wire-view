import Foundation

struct DeviceProfile: Codable, Equatable {
    let identity: String
    var name: String
    var settings: StreamSettings
    let hostPort: UInt16
}

struct DeviceProfiles: Codable {
    static let storageKey = "deviceProfiles.v1"
    var selectedID: String?
    private(set) var profiles: [String: DeviceProfile] = [:]

    var selected: DeviceProfile? { selectedID.flatMap { profiles[$0] } }
    var ordered: [DeviceProfile] {
        profiles.values.sorted { ($0.name, $0.identity) < ($1.name, $1.identity) }
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.selectedID == nil || value.selected != nil,
              Set(value.profiles.values.map(\.hostPort)).count == value.profiles.count,
              value.profiles.allSatisfy({ key, profile in
                  key == profile.identity && key.count == 64 && key.allSatisfy { $0.isHexDigit }
                    && profile.hostPort >= 27183 && StreamSettings.supportedFrameRates.contains(profile.settings.fps)
              }) else { return Self() }
        return value
    }

    @discardableResult
    mutating func remember(_ device: USBDevice, initialSettings: StreamSettings = .balanced) throws -> DeviceProfile {
        let id = device.identity
        if var existing = profiles[id] {
            existing.name = device.name
            profiles[id] = existing
            return existing
        }
        let used = Set(profiles.values.map(\.hostPort))
        guard let port = (27183...65535).lazy.map({ UInt16($0) }).first(where: { !used.contains($0) }) else {
            throw CocoaError(.coderInvalidValue)
        }
        let profile = DeviceProfile(identity: id, name: device.name, settings: initialSettings, hostPort: port)
        profiles[id] = profile
        return profile
    }

    mutating func select(_ identity: String) throws {
        guard profiles[identity] != nil else { throw CocoaError(.coderInvalidValue) }
        selectedID = identity
    }

    mutating func update(_ settings: StreamSettings) throws {
        guard let id = selectedID, var profile = profiles[id], StreamSettings.supportedFrameRates.contains(settings.fps) else {
            throw CocoaError(.coderInvalidValue)
        }
        profile.settings = settings
        profiles[id] = profile
    }

    func save(to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}

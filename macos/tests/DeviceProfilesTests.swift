import Foundation

@main struct DeviceProfilesTests {
    static func main() throws {
        let suite = "dev.wireview.devices-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = USBDevice(serial: "fixture-tablet-A", transport: "7", name: "Same Model")
        let b = USBDevice(serial: "fixture-tablet-B", transport: "8", name: "Same Model")
        precondition(a.identity != b.identity && a.identity.count == 64)
        precondition(a.identity == USBDevice(serial: a.serial, transport: "99").identity)
        var profiles = DeviceProfiles.load(from: defaults)
        try profiles.remember(a, initialSettings: .smooth)
        try profiles.select(a.identity)
        var settingsA = StreamSettings.smooth
        settingsA.size = .medium
        settingsA.sourceUUID = "screen-A"
        try profiles.update(settingsA)
        try profiles.remember(b)
        try profiles.select(b.identity)
        precondition(profiles.selected?.settings == .balanced)
        var settingsB = StreamSettings.balanced
        settingsB.quality = .sharp
        settingsB.fps = 30
        try profiles.update(settingsB)
        try profiles.save(to: defaults)
        profiles = DeviceProfiles.load(from: defaults)
        precondition(profiles.selectedID == b.identity && profiles.selected?.settings == settingsB)
        precondition(profiles.profiles[a.identity]?.settings == settingsA)
        precondition(profiles.profiles[a.identity]?.hostPort != profiles.profiles[b.identity]?.hostPort)
        try profiles.select(a.identity)
        precondition(profiles.selected?.settings == settingsA)
        for rate in [90, 120] {
            var high = settingsA
            high.fps = rate
            try profiles.update(high)
            try profiles.save(to: defaults)
            precondition(DeviceProfiles.load(from: defaults).selected?.settings.fps == rate)
            precondition(DeviceProfiles.load(from: defaults).profiles[b.identity]?.settings == settingsB)
        }
        let bytes = defaults.data(forKey: DeviceProfiles.storageKey)!
        let json = String(decoding: bytes, as: UTF8.self)
        precondition(!json.contains(a.serial) && !json.contains(b.serial))
        let parsed = USBDevice.parse("fixture device usb:0-1 model:Test_Tablet transport_id:8")
        precondition(parsed.first?.name == "Test Tablet")
        precondition(USBDevice.parse("fixture device model:WiFi_Tablet transport_id:8").isEmpty)
        defaults.set(Data("broken".utf8), forKey: DeviceProfiles.storageKey)
        precondition(DeviceProfiles.load(from: defaults).profiles.isEmpty)
        print("设备配置隔离、重启恢复、同型号区分、端口隔离、原始身份不落盘、USB 筛选通过")
    }
}

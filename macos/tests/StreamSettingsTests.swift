import Foundation

@main struct StreamSettingsTests {
    static func main() throws {
        let name = "dev.wireview.settings-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        precondition(StreamSettings.load(from: defaults) == .balanced)
        let source = "test-screen-uuid"
        var chosen = StreamSettings.smooth
        chosen.sourceUUID = source
        try chosen.save(to: defaults)
        precondition(StreamSettings.load(from: defaults) == chosen)
        precondition(StreamSettings.smooth.fps == 60 && StreamSettings.sharp.fps == 60)
        for rate in StreamSettings.supportedFrameRates {
            chosen.fps = rate
            try chosen.save(to: defaults)
            precondition(StreamSettings.load(from: defaults).fps == rate)
        }
        precondition(VideoSize.allCases.allSatisfy { $0.width % 2 == 0 && $0.height % 2 == 0 && $0.width <= 4096 })
        defaults.set(Data("invalid".utf8), forKey: StreamSettings.storageKey)
        precondition(StreamSettings.load(from: defaults) == .balanced)
        chosen.fps = 0
        defaults.set(try JSONEncoder().encode(chosen), forKey: StreamSettings.storageKey)
        precondition(StreamSettings.load(from: defaults) == .balanced)
        do { try chosen.save(to: defaults); preconditionFailure("不应保存无效帧率") }
        catch { }
        print("预设、设置持久化、来源身份、损坏配置和帧率验证通过")
    }
}

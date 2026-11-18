import AppKit

@main struct MenuSettingsTests {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "dev.wireview.menu-test.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let controller = AppController(preferences: preferences, adb: nil)
        app.delegate = controller
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Task { @MainActor in
                let menu: () -> NSMenu = {
                    let value = NSMenu()
                    controller.menuNeedsUpdate(value)
                    return value
                }
                let select: ([String]) -> Void = { path in
                    var current = menu()
                    for name in path.dropLast() { current = current.item(withTitle: name)!.submenu! }
                    let entry = current.item(withTitle: path.last!)!
                    precondition(entry.isEnabled)
                    precondition(app.sendAction(entry.action!, to: entry.target, from: entry))
                }
                let check: (String, String) -> Void = { group, name in
                    let items = menu().item(withTitle: group)!.submenu!.items
                    precondition(items.filter { $0.state == .on }.map(\.title) == [name])
                }
                precondition(!app.windows.contains { $0.styleMask.contains(.titled) })
                select([tr("Presets"), tr("Smooth")])
                check(tr("Size"), "1280 × 800")
                check(tr("Frame rate"), tr("%d fps", arguments: [60]))
                check(tr("Quality"), tr("Data saver"))
                precondition(StreamSettings.load(from: preferences) == .smooth)
                select([tr("Size"), "1600 × 1000"])
                check(tr("Size"), "1600 × 1000")
                precondition(menu().item(withTitle: tr("Presets"))!.submenu!.items.allSatisfy { $0.state == .off })
                select([tr("Frame rate"), tr("%d fps", arguments: [30])])
                check(tr("Frame rate"), tr("%d fps", arguments: [30]))
                for rate in [90, 120] {
                    select([tr("Frame rate"), tr("%d fps", arguments: [rate])])
                    check(tr("Frame rate"), tr("%d fps", arguments: [rate]))
                    precondition(StreamSettings.load(from: preferences).fps == rate)
                }
                let screenItems = menu().item(withTitle: tr("Screen"))!.submenu!.items
                if let screen = screenItems.first(where: { $0.representedObject as? String != "" }) {
                    select([tr("Screen"), screen.title])
                    let identity = StreamSettings.load(from: preferences).sourceUUID
                    precondition(identity != nil)
                    select([tr("Presets"), tr("Balanced")])
                    precondition(StreamSettings.load(from: preferences).sourceUUID == identity)
                    check(tr("Screen"), screen.title)
                }
                select([tr("Screen"), tr("Extended desktop")])
                select([tr("Quality"), tr("Clear")])
                check(tr("Quality"), tr("Clear"))
                select([tr("Presets"), tr("Smooth")])
                print("纯菜单栏无窗口、各组单选勾选、预设、来源保留和即时保存通过")

                let video = CommandLine.arguments.contains("--video")
                let tabletA: USBDevice
                if video {
                    let listing = ADBClient.installed()!(["devices", "-l"])
                    let connected = USBDevice.parse(listing.output)
                    precondition(listing.status == 0 && connected.count == 1, "视频测试需要一台已授权的 USB 测试设备")
                    tabletA = connected[0]
                } else { tabletA = USBDevice(serial: "fixture-A", transport: "21", name: "Tablet") }
                let tabletB = USBDevice(serial: "fixture-B", transport: "22", name: "Tablet B")
                controller.devicesChanged([tabletA, tabletB])
                select([tr("Android devices"), tabletA.name])
                check(tr("Presets"), tr("Smooth")) // First device inherits the old global settings.
                select([tr("Size"), "1600 × 1000"])
                select([tr("Android devices"), tabletB.name])
                check(tr("Presets"), tr("Balanced")) // New device starts with its own defaults.
                select([tr("Quality"), tr("Clear")])
                select([tr("Frame rate"), tr("%d fps", arguments: [30])])
                select([tr("Android devices"), tabletA.name])
                check(tr("Size"), "1600 × 1000")
                check(tr("Quality"), tr("Data saver"))
                check(tr("Frame rate"), tr("%d fps", arguments: [60]))
                controller.devicesChanged([tabletB])
                check(tr("Android devices"), tabletA.name + tr("Offline"))
                check(tr("Size"), "1600 × 1000")
                controller.devicesChanged([tabletA, tabletB])
                select([tr("Android devices"), tabletB.name])
                check(tr("Quality"), tr("Clear"))
                check(tr("Frame rate"), tr("%d fps", arguments: [30]))
                select([tr("Android devices"), tabletA.name])
                select([tr("Presets"), tr("Smooth")])
                precondition(DeviceProfiles.load(from: preferences).selectedID == tabletA.identity)
                for rate in [90, 120] {
                    select([tr("Frame rate"), tr("%d fps", arguments: [rate])])
                    check(tr("Frame rate"), tr("%d fps", arguments: [rate]))
                    precondition(DeviceProfiles.load(from: preferences).selected?.settings.fps == rate)
                }
                select([tr("Presets"), tr("Smooth")])
                let sameModel = [USBDevice(serial: "fixture-C", transport: "23", name: "Identical Model"),
                                 USBDevice(serial: "fixture-D", transport: "24", name: "Identical Model")]
                controller.devicesChanged([tabletA, tabletB] + sameModel)
                let identicalTitles = menu().item(withTitle: tr("Android devices"))!.submenu!.items.map(\.title)
                    .filter { $0.hasPrefix("Identical Model") }
                precondition(identicalTitles.count == 2 && Set(identicalTitles).count == 2)
                precondition(identicalTitles.allSatisfy { !$0.contains("fixture-") })
                controller.devicesChanged([tabletA, tabletB])
                print("设备菜单、首台迁移、A/B 配置切换恢复、离线保留目标通过")

                if !video {
                    // Losing and regaining USB during startup requires a fresh Start action.
                    select([tr("More"), tr("Test pattern")])
                    controller.devicesChanged([tabletB])
                    controller.devicesChanged([tabletA, tabletB])
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    precondition(menu().items[0].title == tr("USB tablet disconnected. Sharing stopped."))
                    precondition(menu().item(withTitle: tr("Start display"))!.isEnabled)
                    controller.devicesChanged([])
                    precondition(!menu().item(withTitle: tr("Start display"))!.isEnabled)
                }

                if CommandLine.arguments.contains("--video") {
                    let waitFor: (String) async -> Void = { title in
                        for _ in 0..<40 {
                            if menu().items[0].title == title { return }
                            try? await Task.sleep(nanoseconds: 200_000_000)
                        }
                        preconditionFailure("菜单状态应为 \(title)，实际 \(menu().items[0].title)")
                    }
                    select([tr("More"), tr("Test pattern")])
                    precondition(!menu().items[1].isEnabled)
                    await waitFor(tr("Testing"))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    check(tr("More"), tr("Test pattern"))
                    select([tr("Quality"), tr("Clear")])
                    await waitFor(tr("Testing"))
                    select([tr("Size"), "1600 × 1000"])
                    await waitFor(tr("Testing"))
                    select([tr("Android devices"), tabletB.name])
                    await waitFor(tr("USB tablet disconnected. Sharing stopped."))
                    precondition(!menu().item(withTitle: tr("Start display"))!.isEnabled)
                    check(tr("Quality"), tr("Clear"))
                    check(tr("Frame rate"), tr("%d fps", arguments: [30]))
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    precondition(menu().item(withTitle: tr("Stop display")) == nil)
                    select([tr("Android devices"), tabletA.name])
                    select([tr("More"), tr("Test pattern")])
                    await waitFor(tr("Testing"))
                    check(tr("Size"), "1600 × 1000")
                    check(tr("Frame rate"), tr("%d fps", arguments: [60]))
                    select([tr("Presets"), tr("Balanced")])
                    await waitFor(tr("Testing"))
                    select([tr("Frame rate"), tr("%d fps", arguments: [30])])
                    await waitFor(tr("Testing"))
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    check(tr("Frame rate"), tr("%d fps", arguments: [30]))
                    if CommandLine.arguments.contains("--high-fps") {
                        select([tr("Presets"), tr("Smooth")])
                        await waitFor(tr("Testing"))
                        for rate in [90, 120] {
                            print("开始高帧率测试：\(rate) fps，1280×800")
                            select([tr("Frame rate"), tr("%d fps", arguments: [rate])])
                            await waitFor(tr("Testing"))
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                            check(tr("Frame rate"), tr("%d fps", arguments: [rate]))
                        }
                        print("90/120 目标会话建立和自动重连通过；实际帧率需结合接收端及呈现统计")
                    }
                    select([tr("Stop display")])
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    precondition(menu().items[0].title == tr("Stopped"))
                    precondition(menu().item(withTitle: tr("Start display"))!.isEnabled)
                    let quality = menu().item(withTitle: tr("Quality"))!.submenu!
                    select([tr("Quality"), quality.item(withTitle: tr("Data saver"))!.state == .on ? tr("Balanced") : tr("Data saver")])
                    precondition(menu().item(withTitle: tr("Start display"))!.isEnabled)
                    precondition(menu().items[0].title == tr("Not started"))
                    precondition(!app.windows.contains { $0.styleMask.contains(.titled) })
                    print("真实 USB 视频自动重连、画质/尺寸/帧率切换、A/B 端口隔离、切回恢复及主动停止通过")
                }
                preferences.removePersistentDomain(forName: suite)
                exit(0)
            }
        }
        app.run()
        withExtendedLifetime(controller) {}
    }
}

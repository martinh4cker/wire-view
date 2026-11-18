import AppKit
import ColorSync

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var sender: Sender?
    private var busy = false
    private var testPattern = false
    private var requestedTouchPermission = false
    private let preferences: UserDefaults
    private var config: StreamSettings
    private var profiles: DeviceProfiles
    private var devices: [USBDevice] = []
    private var deviceMonitor: USBDeviceMonitor?
    private let adb: USBReconnect.Run?
    private var sessionRequested = false
    private var sessionDevice: USBDevice?
    private var lostDevice = false
    private var status = tr("Not started")
    private var detail = ""

    init(preferences: UserDefaults = .standard, adb: USBReconnect.Run? = ADBClient.installed()) {
        self.preferences = preferences
        self.profiles = DeviceProfiles.load(from: preferences)
        self.config = profiles.selected?.settings ?? StreamSettings.load(from: preferences)
        self.adb = adb
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: tr("Wired secondary display"))
        item.button?.toolTip = tr("Wired secondary display") + " · " + tr("Not started")
        item.menu = NSMenu()
        item.menu?.autoenablesItems = false
        item.menu?.delegate = self
        if let adb {
            deviceMonitor = USBDeviceMonitor(run: adb, changed: { [weak self] in self?.devicesChanged($0) })
            deviceMonitor?.start()
        }
        if CommandLine.arguments.contains("--30fps") { config.fps = 30 }
        if CommandLine.arguments.contains("--test-pattern") { startTest() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let headline = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        headline.isEnabled = false
        headline.toolTip = detail.isEmpty ? config.summary : detail
        menu.addItem(headline)
        add(sender == nil ? tr("Start display") : tr("Stop display"), action: #selector(toggleSession), to: menu)
        if sender == nil, selectedUSBDevice == nil { menu.items.last?.isEnabled = false }
        menu.addItem(.separator())

        let destinations = submenu(tr("Android devices"), in: menu)
        var entries = devices.map { ($0.identity, $0.name, true) }
        entries += profiles.ordered.filter { profile in !devices.contains { $0.identity == profile.identity } }
            .map { ($0.identity, $0.name, false) }
        for (identity, name, connected) in entries {
            let duplicate = entries.filter { $0.1 == name }.count > 1
            let title = name + (duplicate ? " · \(identity.prefix(6))" : "") + (connected ? "" : tr("Offline"))
            add(title, action: #selector(selectDevice(_:)), value: identity, checked: profiles.selectedID == identity, to: destinations)
        }
        if entries.isEmpty {
            let empty = NSMenuItem(title: adb == nil ? tr("No ADB found") : tr("No authorized USB Android device found"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            destinations.addItem(empty)
        }

        let presets = submenu(tr("Presets"), in: menu)
        for (name, value) in [(tr("Smooth"), StreamSettings.smooth), (tr("Balanced"), .balanced), (tr("Sharp"), .sharp)] {
            let checked = config.size == value.size && config.fps == value.fps && config.quality == value.quality
            add(name, action: #selector(selectPreset(_:)), value: value.size.rawValue, checked: checked, to: presets)
        }
        let sizes = submenu(tr("Size"), in: menu)
        for value in VideoSize.allCases {
            add(value.title, action: #selector(selectSize(_:)), value: value.rawValue, checked: config.size == value, to: sizes)
        }
        let qualities = submenu(tr("Quality"), in: menu)
        for (name, value) in [(tr("Data saver"), VideoQuality.economy), (tr("Balanced"), .balanced), (tr("Clear"), .sharp)] {
            add(name, action: #selector(selectQuality(_:)), value: value.rawValue, checked: config.quality == value, to: qualities)
        }
        let rates = submenu(tr("Frame rate"), in: menu)
        for value in StreamSettings.supportedFrameRates.reversed() {
            add(tr("%d fps", arguments: [value]), action: #selector(selectRate(_:)), value: String(value), checked: config.fps == value, to: rates)
        }
        let screens = submenu(tr("Screen"), in: menu)
        add(tr("Extended desktop"), action: #selector(selectScreen(_:)), value: "", checked: config.sourceUUID == nil, to: screens)
        var foundSelection = config.sourceUUID == nil
        for screen in NSScreen.screens where screen.localizedName != "WireView" {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            let identity = CFUUIDCreateString(nil, uuid) as String
            let checked = config.sourceUUID == identity
            foundSelection = foundSelection || checked
            add(tr("Mirror %@", arguments: [screen.localizedName]), action: #selector(selectScreen(_:)), value: identity, checked: checked, to: screens)
        }
        if !foundSelection {
            let missing = NSMenuItem(title: tr("Selected display is disconnected"), action: nil, keyEquivalent: "")
            missing.state = .on
            missing.isEnabled = false
            screens.addItem(missing)
        }
        menu.addItem(.separator())
        let more = submenu(tr("More"), in: menu)
        add(tr("Display arrangement…"), action: #selector(openDisplays), to: more, alwaysEnabled: true)
        add(tr("Screen recording permission…"), action: #selector(openPermissions), to: more, alwaysEnabled: true)
        add(tr("Test pattern"), action: #selector(startTest), checked: sender != nil && testPattern, to: more)
        if selectedUSBDevice == nil { more.items.last?.isEnabled = false }
        add(tr("Quit"), action: #selector(quit), to: menu)
    }

    private func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        entry.submenu = submenu
        menu.addItem(entry)
        return submenu
    }

    private func add(_ title: String, action: Selector, value: String? = nil, checked: Bool = false,
                     to menu: NSMenu, alwaysEnabled: Bool = false) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.representedObject = value
        entry.state = checked ? .on : .off
        entry.isEnabled = alwaysEnabled || !busy
        menu.addItem(entry)
    }

    private var selectedUSBDevice: USBDevice? {
        devices.first { $0.identity == profiles.selectedID }
    }

    // Called on the main thread; discovery never starts recording by itself.
    func devicesChanged(_ next: [USBDevice]) {
        devices = next
        if sessionRequested, let target = sessionDevice,
           !next.contains(where: { $0.identity == target.identity && $0.transport == target.transport }) {
            lostDevice = true
            sessionRequested = false
            if !busy { changeSession(start: false, disconnected: true) }
        }
        if profiles.selectedID == nil, next.count == 1, let first = next.first {
            selectDeviceID(first.identity)
        }
    }

    @objc private func selectDevice(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        selectDeviceID(id)
    }

    private func selectDeviceID(_ id: String) {
        guard !busy, id != profiles.selectedID else { return }
        do {
            var updated = profiles
            let first = updated.profiles.isEmpty
            if let device = devices.first(where: { $0.identity == id }) {
                try updated.remember(device, initialSettings: first ? config : .balanced)
            }
            try updated.select(id)
            try updated.save(to: preferences)
            if first, let placement = TabletLayoutMemory.saved(in: preferences) {
                try TabletLayoutMemory.save(placement, in: preferences, deviceID: id)
            }
            profiles = updated
            config = updated.selected!.settings
            if sessionRequested { changeSession(start: true, testing: testPattern) }
            else { report(tr("Not started")) }
        } catch { report(tr("Device settings could not be saved"), detail: error.localizedDescription) }
    }

    @objc private func selectPreset(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String else { return }
        var next: StreamSettings
        switch raw {
        case VideoSize.compact.rawValue: next = .smooth
        case VideoSize.large.rawValue: next = .sharp
        default: next = .balanced
        }
        next.sourceUUID = config.sourceUUID
        apply(next)
    }

    @objc private func selectSize(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let value = VideoSize(rawValue: raw) else { return }
        var next = config; next.size = value; apply(next)
    }

    @objc private func selectQuality(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let value = VideoQuality(rawValue: raw) else { return }
        var next = config; next.quality = value; apply(next)
    }

    @objc private func selectRate(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let value = Int(raw), StreamSettings.supportedFrameRates.contains(value) else { return }
        var next = config; next.fps = value; apply(next)
    }

    @objc private func selectScreen(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String else { return }
        var next = config; next.sourceUUID = raw.isEmpty ? nil : raw; apply(next)
    }

    private func apply(_ next: StreamSettings) {
        guard !busy, next != config else { return }
        do {
            if profiles.selectedID != nil {
                var updated = profiles
                try updated.update(next)
                try updated.save(to: preferences)
                profiles = updated
            } else { try next.save(to: preferences) }
        }
        catch { report(tr("Settings could not be saved"), detail: error.localizedDescription); return }
        config = next
        if sessionRequested { changeSession(start: true, testing: testPattern) }
        else { report(tr("Not started")) }
    }

    @objc private func toggleSession() {
        guard !busy else { return }
        changeSession(start: sender == nil)
    }

    @objc private func startTest() {
        guard !busy else { return }
        changeSession(start: true, testing: true)
    }

    private func changeSession(start: Bool, testing: Bool = false, disconnected: Bool = false) {
        guard !busy else { return }
        let target = start ? selectedUSBDevice : nil
        sessionRequested = target != nil
        sessionDevice = target
        lostDevice = disconnected
        testPattern = testing
        if start, target == nil, sender == nil {
            report(tr("Connect the selected USB tablet to start."))
            return
        }
        busy = true
        report(target != nil ? tr("Connecting…") : tr("Stopping…"))
        Task { @MainActor in
            if let current = sender {
                current.onStatus = nil; current.onMetrics = nil; current.onFailure = nil
                sender = nil
                await current.stop()
            }
            if let target, !lostDevice {
                do {
                    let destination = profiles.selected!
                    let next = try Sender(settings: config, targetDeviceID: destination.identity,
                                          hostPort: destination.hostPort, preferences: preferences, usbTransport: target.transport)
                    sender = next
                    testPattern = testing
                    next.onStatus = { [weak self, weak next] message in
                        guard let self, let next, self.sender === next else { return }
                        if message.hasPrefix(tr("Connected")) {
                            let needsTouchPermission = !testing && self.config.sourceUUID == nil && !CGPreflightPostEventAccess()
                            self.report(testing ? tr("Testing") : tr("Connected"),
                                        detail: needsTouchPermission ? tr("Allow WireView in Privacy & Security → Accessibility to use touch.") : message)
                        }
                        else if message.hasPrefix(tr("Waiting for tablet")) { self.report(tr("Waiting for tablet"), detail: message) }
                        else { self.detail = message }
                    }
                    next.onFailure = { [weak self, weak next] message in
                        Task { @MainActor in
                            guard let self, let next else { return }
                            while self.busy { try? await Task.sleep(nanoseconds: 50_000_000) }
                            guard self.sender === next else { return }
                            await self.fail(message)
                        }
                    }
                    try await next.start(testPattern: testing)
                    if !lostDevice, !testing, config.sourceUUID == nil, !requestedTouchPermission {
                        requestedTouchPermission = true
                        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
                    }
                    if lostDevice {
                        sender = nil
                        await next.stop()
                        report(tr("USB tablet disconnected. Sharing stopped."))
                    }
                } catch {
                    if let failed = sender { sender = nil; await failed.stop() }
                    sessionRequested = false
                    sessionDevice = nil
                    if lostDevice { report(tr("USB tablet disconnected. Sharing stopped.")) }
                    else { report(tr("Connection failed"), detail: error.localizedDescription) }
                }
            } else if lostDevice || start {
                report(tr("USB tablet disconnected. Sharing stopped."))
            } else { report(tr("Stopped")) }
            if !sessionRequested { sessionDevice = nil }
            busy = false
        }
    }

    private func fail(_ message: String) async {
        sessionRequested = false
        sessionDevice = nil
        busy = true
        if let current = sender {
            current.onStatus = nil; current.onFailure = nil
            sender = nil
            await current.stop()
        }
        report(message == tr("USB tablet disconnected. Sharing stopped.") ? message : tr("Connection stopped"), detail: message)
        busy = false
    }

    private func report(_ text: String, detail: String = "") {
        status = text
        self.detail = detail
        if let device = profiles.selected?.name {
            item?.button?.toolTip = tr("WireView · %@ · %@ · %@", arguments: [device, text, config.summary])
        } else {
            item?.button?.toolTip = tr("WireView · %@ · %@", arguments: [text, config.summary])
        }
        if !detail.isEmpty { print(detail) }
    }

    @objc private func openDisplays() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }

    @objc private func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quit() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            if let sender { await sender.stop() }
            NSApplication.shared.terminate(nil)
        }
    }
}

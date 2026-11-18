import AppKit

setbuf(stdout, nil)
let oldBundleID = "dev.wiredtabletscreen.host"
let newBundleID = "dev.wireview.host"
let migratedKeys = ["streamSettings.v1", "deviceProfiles.v1", "tabletDisplayPlacement.v1"]
if let oldDomain = UserDefaults(suiteName: oldBundleID)?.persistentDomain(forName: oldBundleID) {
    let currentDomain = UserDefaults.standard.persistentDomain(forName: newBundleID) ?? [:]
    for (key, value) in oldDomain where migratedKeys.contains(where: key.hasPrefix) && currentDomain[key] == nil {
        UserDefaults.standard.set(value, forKey: key)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()

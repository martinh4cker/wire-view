import CoreGraphics
import Foundation

@main struct DisplayLayoutTests {
    static func main() throws {
        let main = DisplayLayout.Screen(id: 1, identity: "main", bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let dell = DisplayLayout.Screen(id: 2, identity: "dell", bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080))
        let layout = DisplayLayout(primary: main.id, displays: [main, dell])
        let tablet = CGRect(x: 240, y: 982, width: 960, height: 600)
        guard let saved = layout.position(of: tablet) else { preconditionFailure("平板在主屏下方，应当能识别") }
        precondition(saved == TabletPlacement(anchor: "main", edge: .below, offset: 240))
        let restored = try JSONDecoder().decode(TabletPlacement.self, from: JSONEncoder().encode(saved))
        let reconnectedMain = DisplayLayout.Screen(id: 10, identity: "main", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let reconnectedDell = DisplayLayout.Screen(id: 20, identity: "dell", bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        let reconnected = DisplayLayout(primary: reconnectedMain.id, displays: [reconnectedMain, reconnectedDell])
        precondition(reconnected.restoredOrigin(restored, tabletSize: tablet.size) == CGPoint(x: 240, y: 900))

        let withoutAnchor = DisplayLayout(primary: dell.id, displays: [dell])
        precondition(withoutAnchor.restoredOrigin(saved, tabletSize: tablet.size) == nil)
        let movedDell = DisplayLayout.Screen(id: 2, identity: "dell", bounds: CGRect(x: 0, y: 982, width: 1920, height: 1080))
        let blocked = DisplayLayout(primary: main.id, displays: [main, movedDell])
        precondition(blocked.restoredOrigin(saved, tabletSize: tablet.size) == nil)
        let suite = "dev.wireview.placement-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try TabletLayoutMemory.save(saved, in: defaults, deviceID: "A")
        precondition(TabletLayoutMemory.saved(in: defaults, deviceID: "A") == saved)
        precondition(TabletLayoutMemory.saved(in: defaults, deviceID: "B") == nil)
        precondition(TabletLayoutMemory.saved(in: defaults) == nil)
        print("保存下方位置、跨显示器 ID 恢复、参照缺失和布局冲突检查通过")
    }
}

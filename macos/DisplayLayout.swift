import ColorSync
import CoreGraphics
import Foundation

struct TabletPlacement: Codable, Equatable {
    enum Edge: String, Codable { case left, right, above, below }
    let anchor: String
    let edge: Edge
    let offset: Int

    static func adjacent(to anchor: String, bounds: CGRect, tablet: CGRect) -> (Self, CGFloat)? {
        let sharedWidth = min(bounds.maxX, tablet.maxX) - max(bounds.minX, tablet.minX)
        let sharedHeight = min(bounds.maxY, tablet.maxY) - max(bounds.minY, tablet.minY)
        if sharedHeight > 0 {
            if tablet.maxX == bounds.minX { return (.init(anchor: anchor, edge: .left, offset: Int(tablet.minY - bounds.minY)), sharedHeight) }
            if tablet.minX == bounds.maxX { return (.init(anchor: anchor, edge: .right, offset: Int(tablet.minY - bounds.minY)), sharedHeight) }
        }
        if sharedWidth > 0 {
            if tablet.maxY == bounds.minY { return (.init(anchor: anchor, edge: .above, offset: Int(tablet.minX - bounds.minX)), sharedWidth) }
            if tablet.minY == bounds.maxY { return (.init(anchor: anchor, edge: .below, offset: Int(tablet.minX - bounds.minX)), sharedWidth) }
        }
        return nil
    }

    func origin(near bounds: CGRect, size: CGSize) -> CGPoint {
        // Keep a shared edge even when the anchor's display mode changes.
        let x = bounds.minX + min(max(CGFloat(offset), 1 - size.width), bounds.width - 1)
        let y = bounds.minY + min(max(CGFloat(offset), 1 - size.height), bounds.height - 1)
        switch edge {
        case .left: return CGPoint(x: bounds.minX - size.width, y: y)
        case .right: return CGPoint(x: bounds.maxX, y: y)
        case .above: return CGPoint(x: x, y: bounds.minY - size.height)
        case .below: return CGPoint(x: x, y: bounds.maxY)
        }
    }
}

struct DisplayLayout {
    struct Screen: Equatable {
        let id: CGDirectDisplayID
        let identity: String?
        let bounds: CGRect
    }

    let primary: CGDirectDisplayID
    let displays: [Screen]

    private struct LayoutError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func snapshot(excluding excludedID: CGDirectDisplayID = kCGNullDirectDisplay) throws -> Self {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            throw LayoutError(tr("Could not read the display arrangement."))
        }
        var ids = [CGDirectDisplayID](repeating: kCGNullDirectDisplay, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            throw LayoutError(tr("Could not read the display arrangement."))
        }
        let displays = ids.prefix(Int(count)).filter { $0 != excludedID }.sorted().map { id in
            let identity = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            return Screen(id: id, identity: identity, bounds: CGDisplayBounds(id))
        }
        return Self(primary: CGMainDisplayID(), displays: displays)
    }

    func position(of tablet: CGRect) -> TabletPlacement? {
        displays.compactMap { screen -> (TabletPlacement, CGFloat, Bool)? in
            guard let identity = screen.identity,
                  let (placement, overlap) = TabletPlacement.adjacent(to: identity, bounds: screen.bounds, tablet: tablet) else { return nil }
            return (placement, overlap, screen.id == primary)
        }.max { ($0.1, $0.2 ? 1 : 0) < ($1.1, $1.2 ? 1 : 0) }?.0
    }

    func restoredOrigin(_ saved: TabletPlacement, tabletSize: CGSize) -> CGPoint? {
        guard let anchor = displays.first(where: { $0.identity == saved.anchor }) else { return nil }
        let origin = saved.origin(near: anchor.bounds, size: tabletSize)
        let target = CGRect(origin: origin, size: tabletSize)
        guard !displays.contains(where: {
            let overlap = $0.bounds.intersection(target)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }) else { return nil }
        return origin
    }

    @discardableResult
    func place(_ tablet: CGDirectDisplayID, saved: TabletPlacement?) throws -> Bool {
        guard tablet != primary, CGDisplayIsActive(primary) != 0,
              let rightmost = displays.max(by: { ($0.bounds.maxX, -$0.bounds.minY) < ($1.bounds.maxX, -$1.bounds.minY) }) else {
            throw LayoutError(tr("The original displays are disconnected; the tablet cannot be placed."))
        }
        let mirrored = CGDisplayIsInMirrorSet(tablet) != 0
        let size = CGDisplayBounds(tablet).size
        let restored = !mirrored && size.width > 0 && size.height > 0 ? saved.flatMap { restoredOrigin($0, tabletSize: size) } : nil
        let target = restored ?? CGPoint(x: rightmost.bounds.maxX, y: rightmost.bounds.minY)
        let changed = displays.filter { CGDisplayBounds($0.id).origin != $0.bounds.origin }
        if mirrored || !changed.isEmpty || CGMainDisplayID() != primary || CGDisplayBounds(tablet).origin != target {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else {
                throw LayoutError(tr("Could not position the secondary display."))
            }
            let unmirrored = !mirrored || CGConfigureDisplayMirrorOfDisplay(config, tablet, kCGNullDirectDisplay) == .success
            let primaryKept = CGMainDisplayID() == primary || CGConfigureDisplayOrigin(config, primary, 0, 0) == .success
            let positionsKept = changed.filter { $0.id != primary }.allSatisfy {
                CGConfigureDisplayOrigin(config, $0.id, Int32($0.bounds.minX), Int32($0.bounds.minY)) == .success
            }
            guard unmirrored, primaryKept, positionsKept,
                  CGConfigureDisplayOrigin(config, tablet, Int32(target.x), Int32(target.y)) == .success else {
                CGCancelDisplayConfiguration(config)
                throw LayoutError(tr("Could not place the tablet while preserving the existing display arrangement."))
            }
            guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
                throw LayoutError(tr("Could not apply the display position."))
            }
        }
        guard CGMainDisplayID() == primary, CGDisplayIsInMirrorSet(tablet) == 0,
              displays.allSatisfy({ CGDisplayBounds($0.id).origin == $0.bounds.origin }) else {
            throw LayoutError(tr("macOS did not preserve the primary display, arrangement, or tablet position."))
        }
        if restored != nil {
            if CGDisplayBounds(tablet).origin == target { return true }
            return try place(tablet, saved: nil)
        }
        guard CGDisplayBounds(tablet).minX >= rightmost.bounds.maxX else { throw LayoutError(tr("macOS did not place the tablet at the rightmost edge.")) }
        return false
    }
}

private enum DisplayReconfiguration {
    static let notification = Notification.Name("dev.wireview.displayReconfiguration")
    // Register once per process; the C callback needs no Swift object pointer.
    static let registration = CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
        guard !flags.contains(.beginConfigurationFlag) else { return }
        DispatchQueue.main.async { NotificationCenter.default.post(name: notification, object: nil) }
    }, nil)
}

final class TabletLayoutMemory {
    private let defaults: UserDefaults
    private static let key = "tabletDisplayPlacement.v1"
    private let deviceID: String?
    private let tablet: CGDirectDisplayID
    private var previous: DisplayLayout
    private var previousBounds: CGRect
    private var observer: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    private static func storageKey(_ deviceID: String?) -> String { deviceID.map { key + "." + $0 } ?? key }

    static func saved(in defaults: UserDefaults = .standard, deviceID: String? = nil) -> TabletPlacement? {
        defaults.data(forKey: storageKey(deviceID)).flatMap { try? JSONDecoder().decode(TabletPlacement.self, from: $0) }
    }

    static func save(_ placement: TabletPlacement, in defaults: UserDefaults = .standard, deviceID: String? = nil) throws {
        defaults.set(try JSONEncoder().encode(placement), forKey: storageKey(deviceID))
    }

    init(tablet: CGDirectDisplayID, defaults: UserDefaults = .standard, deviceID: String? = nil) throws {
        guard DisplayReconfiguration.registration == .success else {
            throw CocoaError(.featureUnsupported)
        }
        self.tablet = tablet
        self.defaults = defaults
        self.deviceID = deviceID
        previous = try DisplayLayout.snapshot(excluding: tablet)
        previousBounds = CGDisplayBounds(tablet)
        observer = NotificationCenter.default.addObserver(forName: DisplayReconfiguration.notification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.scheduleObservation()
        }
    }

    deinit {
        pending?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func scheduleObservation() {
        pending?.cancel()
        let pending = DispatchWorkItem { [weak self] in self?.recordMove() }
        self.pending = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: pending)
    }

    private func recordMove() {
        guard CGDisplayIsActive(tablet) != 0, let current = try? DisplayLayout.snapshot(excluding: tablet) else { return }
        let bounds = CGDisplayBounds(tablet)
        let movedAlone = current.primary == previous.primary && current.displays == previous.displays
            && previousBounds.origin != bounds.origin && previousBounds.size == bounds.size
        previous = current
        previousBounds = bounds
        guard movedAlone, current.primary != tablet, CGDisplayIsInMirrorSet(tablet) == 0,
              let placement = current.position(of: bounds) else { return }
        do {
            try Self.save(placement, in: defaults, deviceID: deviceID)
            print("已记住平板的屏幕位置。")
        } catch {
            print("无法保存平板的屏幕位置：\(error)")
        }
    }
}

import Foundation

enum VideoSize: String, Codable, CaseIterable {
    case compact, medium, standard, large
    var width: Int { switch self { case .compact: return 1280; case .medium: return 1600; case .standard: return 1920; case .large: return 2560 } }
    var height: Int { width * 5 / 8 }
    var title: String { "\(width) × \(height)" }
}

enum VideoQuality: String, Codable, CaseIterable {
    case economy, balanced, sharp
    var bitrate: Int { switch self { case .economy: return 4_000_000; case .balanced: return 10_000_000; case .sharp: return 20_000_000 } }
    var title: String {
        let name: String
        switch self { case .economy: name = tr("Data saver"); case .balanced: name = tr("Balanced"); case .sharp: name = tr("Clear") }
        return "\(name) · \(bitrate / 1_000_000) Mbps"
    }
}

struct StreamSettings: Codable, Equatable {
    var size: VideoSize = .standard
    var fps: Int = 60
    var quality: VideoQuality = .balanced
    // Stable display UUID; nil creates a separate desktop. Do not persist a transient display ID.
    var sourceUUID: String?
    static let storageKey = "streamSettings.v1"
    static let supportedFrameRates = [30, 60, 90, 120]

    static var smooth: Self { Self(size: .compact, quality: .economy) }
    static var balanced: Self { Self() }
    static var sharp: Self { Self(size: .large, quality: .sharp) }
    var summary: String { "\(size.title) · \(fps) fps · \(quality.bitrate / 1_000_000) Mbps" }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey), let value = try? JSONDecoder().decode(Self.self, from: data),
              supportedFrameRates.contains(value.fps) else { return Self() }
        return value
    }

    func save(to defaults: UserDefaults = .standard) throws {
        guard Self.supportedFrameRates.contains(fps) else { throw CocoaError(.coderInvalidValue) }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}

struct StreamMetrics {
    let acknowledgedFPS: Double?
    let latencyMedian: Double?
    let latencyP95: Double?
}

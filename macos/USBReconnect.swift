import Foundation
import CryptoKit

struct ADBResult {
    let status: Int32
    let output: String
}

struct USBDevice: Equatable {
    let serial: String
    let transport: String
    var name: String = tr("Android device")
    // Raw serial stays in memory, never in preferences, logs, or menu titles.
    var identity: String { SHA256.hash(data: Data(serial.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func parse(_ text: String) -> [Self] {
        text.split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard columns.count >= 2, columns[1] == "device",
                  columns.contains(where: { $0.hasPrefix("usb:") }),
                  let transport = columns.first(where: { $0.hasPrefix("transport_id:") }) else { return nil }
            let model = columns.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return Self(serial: columns[0], transport: String(transport.dropFirst("transport_id:".count)), name: model ?? tr("Android device"))
        }
    }
}

enum ADBClient {
    static func installed() -> USBReconnect.Run? {
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/adb" }
            + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return { arguments in
            let task = Process()
            let output = Pipe()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = arguments
            task.standardOutput = output
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { return ADBResult(status: -1, output: "") }
            let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            timeout.cancel()
            return ADBResult(status: task.terminationStatus, output: String(decoding: bytes, as: UTF8.self))
        }
    }
}

final class USBDeviceMonitor {
    private let run: USBReconnect.Run
    private let changed: ([USBDevice]) -> Void
    private let queue = DispatchQueue(label: "dev.wireview.device-list")
    private var timer: DispatchSourceTimer?
    private var previous: [USBDevice]?

    init(run: @escaping USBReconnect.Run, changed: @escaping ([USBDevice]) -> Void) {
        self.run = run
        self.changed = changed
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let result = self.run(["devices", "-l"])
            let devices = result.status == 0 ? USBDevice.parse(result.output) : []
            guard devices != self.previous else { return }
            self.previous = devices
            DispatchQueue.main.async { [weak self] in self?.changed(devices) }
        }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }
}

final class USBReconnect {
    typealias Run = ([String]) -> ADBResult
    private let run: Run
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "dev.wireview.usb")
    private var timer: DispatchSourceTimer?
    private var selectedSerial: String?
    private let targetID: String?
    private let hostPort: String
    private var startedTransport: String?
    private var lastMessage: String?
    private let port = "tcp:27183"

    init(run: @escaping Run, targetID: String? = nil, hostPort: UInt16 = 27183,
         log: @escaping (String) -> Void = { print($0) }) {
        self.run = run
        self.log = log
        self.targetID = targetID
        self.hostPort = "tcp:\(hostPort)"
    }

    static func installed(targetID: String? = nil, hostPort: UInt16 = 27183,
                          log: @escaping (String) -> Void = { print($0) }) -> USBReconnect? {
        guard let run = ADBClient.installed() else {
            log(tr("ADB was not found; install Android Platform-Tools to restore USB connection."))
            return nil
        }
        return USBReconnect(run: run, targetID: targetID, hostPort: hostPort, log: log)
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    func stop() {
        queue.sync { timer?.cancel(); timer = nil }
    }

    // Run serially on the USB queue; tests can drive one poll at a time.
    func poll() {
        let listing = run(["devices", "-l"])
        guard listing.status == 0 else { report(tr("ADB is unavailable; waiting to retry.")); return }
        let devices = USBDevice.parse(listing.output)
        let device: USBDevice
        if let targetID {
            guard let selected = devices.first(where: { $0.identity == targetID }) else {
                startedTransport = nil
                report(tr("Selected USB tablet disconnected; reconnect it to resume."))
                return
            }
            device = selected
        } else if let selectedSerial {
            guard let selected = devices.first(where: { $0.serial == selectedSerial }) else {
                startedTransport = nil
                report(tr("USB tablet disconnected; reconnect it to resume."))
                return
            }
            device = selected
        } else {
            guard devices.count == 1, let first = devices.first else {
                report(devices.isEmpty ? tr("Waiting for an authorized USB tablet.") : tr("Multiple USB devices found; leave only the tablet you want to use connected."))
                return
            }
            device = first
            selectedSerial = first.serial
        }
        let target = ["-t", device.transport]
        let mappings = run(target + ["reverse", "--list"])
        guard mappings.status == 0 else { report(tr("USB connection is not ready; retrying.")); return }
        let existing = mappings.output.split(separator: "\n").map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
            .first { $0.count == 3 && $0[1] == port }
        if let existing {
            guard existing[2] == hostPort else { report(tr("Tablet port is in use; the existing forwarding was left unchanged.")); return }
        } else {
            guard run(target + ["reverse", "--no-rebind", port, hostPort]).status == 0 else {
                report(tr("USB forwarding failed; retrying."))
                return
            }
        }
        if startedTransport != device.transport {
            let launched = run(target + ["shell", "am", "start", "-n", "dev.wireview.receiver/.MainActivity"])
            guard launched.status == 0, !launched.output.contains("Error") else {
                report(tr("Install the receiver app on the tablet; connection will retry automatically."))
                return
            }
            startedTransport = device.transport
        }
        report(tr("USB forwarding is ready; the tablet will reconnect automatically."))
    }

    private func report(_ message: String) {
        guard message != lastMessage else { return }
        lastMessage = message
        log(message)
    }
}

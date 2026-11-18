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
    private var failedPolls = 0

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
            self.failedPolls = result.status == 0 ? 0 : self.failedPolls + 1
            guard result.status == 0 || self.failedPolls >= 3 else { return }
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

// Mutable session state is confined to the USB queue. Tests drive poll serially.
final class USBReconnect: @unchecked Sendable {
    typealias Run = ([String]) -> ADBResult
    private let run: Run
    private let log: (String) -> Void
    private let inputToken: String?
    private let requiredTransport: String?
    private var ownedTransport: String?
    private let onMissing: () -> Void
    private let queue = DispatchQueue(label: "dev.wireview.usb")
    private var timer: DispatchSourceTimer?
    private var selectedSerial: String?
    private let targetID: String?
    private let hostPort: String
    private var startedTransport: String?
    private var lastMessage: String?
    private let port = "tcp:27183"

    init(run: @escaping Run, targetID: String? = nil, hostPort: UInt16 = 27183, inputToken: String? = nil, requiredTransport: String? = nil,
         log: @escaping (String) -> Void = { print($0) }, onMissing: @escaping () -> Void = {}) {
        self.run = run
        self.log = log
        self.onMissing = onMissing
        self.inputToken = inputToken
        self.requiredTransport = requiredTransport
        self.targetID = targetID
        self.hostPort = "tcp:\(hostPort)"
    }

    static func installed(targetID: String? = nil, hostPort: UInt16 = 27183, inputToken: String? = nil, requiredTransport: String? = nil,
                          log: @escaping (String) -> Void = { print($0) }, onMissing: @escaping () -> Void = {}) -> USBReconnect? {
        guard let run = ADBClient.installed() else {
            log(tr("ADB was not found; install Android Platform-Tools to restore USB connection."))
            return nil
        }
        return USBReconnect(run: run, targetID: targetID, hostPort: hostPort, inputToken: inputToken, requiredTransport: requiredTransport, log: log, onMissing: onMissing)
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    deinit { timer?.cancel() }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.timer?.cancel()
                self.timer = nil
                self.removeOwnedMapping()
                continuation.resume()
            }
        }
    }

    private func removeOwnedMapping() {
        guard let transport = ownedTransport else { return }
        ownedTransport = nil
        let target = ["-t", transport]
        let listing = run(target + ["reverse", "--list"])
        if listing.status == 0, let mapped = mappedHost(in: listing.output), mapped == hostPort {
            _ = run(target + ["reverse", "--remove", port])
        }
    }

    private func mappedHost(in output: String) -> Substring? {
        output.split(separator: "\n")
            .map { $0.split(whereSeparator: { $0.isWhitespace }) }
            .first { $0.count == 3 && $0[1] == port }?[2]
    }

    // Run serially on the USB queue; tests can drive one poll at a time.
    func poll() {
        let listing = run(["devices", "-l"])
        guard listing.status == 0 else { report(tr("ADB is unavailable; waiting to retry.")); return }
        let devices = USBDevice.parse(listing.output)
        let device: USBDevice
        if let targetID {
            guard let selected = devices.first(where: { $0.identity == targetID && (requiredTransport == nil || $0.transport == requiredTransport) }) else {
                onMissing()
                startedTransport = nil
                report(tr("Selected USB tablet disconnected; reconnect it to resume."))
                return
            }
            device = selected
        } else if let selectedSerial {
            guard let selected = devices.first(where: { $0.serial == selectedSerial }) else {
                onMissing()
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
        if let existing = mappedHost(in: mappings.output) {
            guard existing == hostPort else { report(tr("Tablet port is in use; the existing forwarding was left unchanged.")); return }
        } else {
            guard run(target + ["reverse", "--no-rebind", port, hostPort]).status == 0 else {
                report(tr("USB forwarding failed; retrying."))
                return
            }
            ownedTransport = device.transport
        }
        if startedTransport != device.transport {
            var args = target + ["shell", "am", "start", "-n", "dev.wireview.receiver/.MainActivity"]
            if let inputToken { args += ["--es", "wireview_input_token", inputToken] }
            let launched = run(args)
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

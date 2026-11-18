import Foundation

@main struct USBReconnectTests {
    static func main() {
        let usb = "test-device device usb:0-1 product:test transport_id:7"
        precondition(USBDevice.parse("network:5555 device transport_id:8\nunauthorized unauthorized usb:0-2").isEmpty)
        var devices = usb
        var mapping = ""
        var calls = [[String]]()
        var launchFails = false
        let monitor = USBReconnect(run: { args in
            calls.append(args)
            if args == ["devices", "-l"] { return .init(status: 0, output: devices) }
            if args.contains("--list") { return .init(status: 0, output: mapping) }
            if args.contains("--no-rebind") {
                mapping = "UsbFfs tcp:27183 tcp:27183"
                return .init(status: 0, output: "")
            }
            precondition(args.contains("shell"))
            return .init(status: 0, output: launchFails ? "Error type 3" : "Starting: Intent")
        }, log: { _ in })
        monitor.poll()
        precondition(calls.count == 4)
        calls = []
        monitor.poll()
        precondition(calls.count == 2) // Existing mapping doesn't relaunch the foreground app.
        devices = ""
        monitor.poll()
        devices = usb.replacingOccurrences(of: "transport_id:7", with: "transport_id:9")
        mapping = ""
        calls = []
        monitor.poll()
        precondition(calls.count == 4 && calls[1].prefix(2) == ["-t", "9"])
        mapping = "UsbFfs tcp:27183 tcp:12345"
        calls = []
        monitor.poll()
        precondition(calls.count == 2 && mapping.hasSuffix("12345"))
        devices = "different-device device usb:0-2 transport_id:11"
        calls = []
        monitor.poll()
        precondition(calls.count == 1) // Do not switch silently to another tablet.
        devices = usb
        mapping = ""
        launchFails = true
        monitor.poll()
        launchFails = false
        calls = []
        monitor.poll()
        precondition(calls.count == 3 && calls.last!.contains("shell"))

        let tabletA = USBDevice(serial: "fixture-A", transport: "21")
        let tabletB = USBDevice(serial: "fixture-B", transport: "22")
        devices = "\(tabletA.serial) device usb:0-1 transport_id:21\n\(tabletB.serial) device usb:0-2 transport_id:22"
        mapping = ""
        calls = []
        var expectedTransport = "22"
        let targeted = USBReconnect(run: { args in
            calls.append(args)
            if args == ["devices", "-l"] { return .init(status: 0, output: devices) }
            precondition(args.prefix(2) == ["-t", expectedTransport])
            if args.contains("--list") { return .init(status: 0, output: mapping) }
            if args.contains("--no-rebind") {
                precondition(args.suffix(2) == ["tcp:27183", "tcp:27184"])
                mapping = "UsbFfs tcp:27183 tcp:27184"
            }
            return .init(status: 0, output: "")
        }, targetID: tabletB.identity, hostPort: 27184, log: { _ in })
        targeted.poll()
        precondition(calls.count == 4)
        devices = "\(tabletA.serial) device usb:0-1 transport_id:21"
        calls = []
        targeted.poll()
        precondition(calls.count == 1) // B unplugged: A must not receive its video.
        devices += "\n\(tabletB.serial) device usb:0-2 transport_id:25"
        calls = []
        expectedTransport = "25"
        targeted.poll()
        precondition(calls.count == 3)
        print("USB-only selection, reconnect, idempotence, conflicts and app-launch retry passed")
        print("多设备指定目标、独立转发端口、拔线不切换其他设备及新 transport 恢复通过")
    }
}

import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ColorSync
import Network
import OSLog
import ScreenCaptureKit
import VideoToolbox

let touchLog = Logger(subsystem: "dev.wireview.host", category: "touch")
private let queue = DispatchQueue(label: "dev.wireview.video")
private func nowMicros() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000 }

private extension Data {
    mutating func push<T: FixedWidthInteger>(_ value: T) {
        let networkOrder = value.bigEndian
        Swift.withUnsafeBytes(of: networkOrder) { append(contentsOf: $0) }
    }
}

private struct PrototypeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// App lifecycle and display ownership stay on the main thread. Video state is confined to
// `queue`; stop waits for that queue before releasing the capture/display on the main thread.
final class Sender: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let settings: StreamSettings
    private let targetDeviceID: String?
    private let hostPort: UInt16
    private let usbTransport: String?
    private var connectionDeadline: UInt64?
    private var connectionFailed = false
    private var clientReadyAt: UInt64?
    private let preferences: UserDefaults
    private var width: Int { settings.size.width }
    private var height: Int { settings.size.height }
    private var fps: Int { settings.fps }
    var onStatus: ((String) -> Void)?
    var onMetrics: ((StreamMetrics) -> Void)?
    var onFailure: ((String) -> Void)?
    private var stopping = false
    private var lastAckAt: UInt64?
    private var measuredFPS: Double?
    private var acknowledgedFrames = 0
    private var ackWindowStart: UInt64?
    private let listener: NWListener
    private var connection: NWConnection?
    private var clientReady = false
    private var needsKeyFrame = true
    private var sending = false
    private var encoding = false
    private var encoder: VTCompressionSession?
    private var timer: DispatchSourceTimer?
    private var frames = 0
    private var captureCount = 0
    private var latencySamples = [Double]()
    private var encodingSamples = [Double]()
    private var display: CGVirtualDisplay?
    private var layoutMemory: TabletLayoutMemory?
    private var stream: SCStream?
    private var touchInput: TouchInput?
    private let inputToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(28)
    private var hasFirstTokenHalf = false
    private var inputAuthorized = false
    private var usbReconnect: USBReconnect?

    init(settings: StreamSettings, targetDeviceID: String? = nil, hostPort: UInt16 = 27183,
         preferences: UserDefaults = .standard, usbTransport: String? = nil) throws {
        self.settings = settings
        self.targetDeviceID = targetDeviceID
        self.hostPort = hostPort
        self.usbTransport = usbTransport
        self.preferences = preferences
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: hostPort)!)
        listener = try NWListener(using: params)
        super.init()
    }

    private func report(_ text: String) {
        print(text)
        DispatchQueue.main.async { [weak self] in self?.onStatus?(text) }
    }

    func start(testPattern: Bool) async throws {
        if !testPattern {
            // Keep settings usable without recording permission. Start only on explicit user action.
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                throw PrototypeError(tr("Screen recording is required. Allow WireView in System Settings, then start again."))
            }
            var captureID: CGDirectDisplayID
            if let sourceUUID = settings.sourceUUID {
                guard let uuid = CFUUIDCreateFromString(nil, sourceUUID as CFString) else {
                    throw PrototypeError(tr("The selected display could not be found. Choose it again in settings."))
                }
                captureID = CGDisplayGetDisplayIDFromUUID(uuid)
                guard captureID != kCGNullDirectDisplay, CGDisplayIsActive(captureID) != 0 else {
                    throw PrototypeError(tr("The selected display is disconnected. Choose another source or create an extended display."))
                }
            } else {
            let layout = try DisplayLayout.snapshot()
            let descriptor = CGVirtualDisplayDescriptor()
            descriptor.name = "WireView"
            descriptor.setDispatchQueue(queue)
            descriptor.maxPixelsWide = UInt32(width)
            descriptor.maxPixelsHigh = UInt32(height)
            descriptor.sizeInMillimeters = CGSize(width: 288, height: 180)
            descriptor.vendorID = 0x5754
            descriptor.productID = 0x5301
            descriptor.serialNum = 1
            let settings = CGVirtualDisplaySettings()
            guard let display = CGVirtualDisplay(descriptor: descriptor),
                  let mode = CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: Double(fps)) else {
                throw PrototypeError(tr("CoreGraphics could not create a virtual display."))
            }
            settings.modes = [mode]
            guard display.apply(settings) else { throw PrototypeError(tr("Could not configure the virtual display mode.")) }
            let restored = try layout.place(display.displayID, saved: TabletLayoutMemory.saved(in: preferences, deviceID: targetDeviceID))
            self.display = display
            layoutMemory = try TabletLayoutMemory(tablet: display.displayID, defaults: preferences, deviceID: targetDeviceID)
            print("\(restored ? "已恢复副屏位置" : "已在最右端创建副屏")：\(display.displayID)，\(width)×\(height) @ \(fps) Hz；保留主屏 \(layout.primary)")
            captureID = display.displayID
            }
            var target: SCDisplay?
            for _ in 0..<20 {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                target = content.displays.first { $0.displayID == captureID }
                if target != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let target else { throw PrototypeError(tr("ScreenCaptureKit could not find the selected display.")) }
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            // The virtual display already sets the cadence. A second throttle can skip a refresh
            // when adjacent capture timestamps land just below the nominal frame interval.
            config.minimumFrameInterval = settings.sourceUUID == nil ? .zero : CMTime(value: 1, timescale: Int32(fps))
            config.scalesToFit = true
            config.preservesAspectRatio = true
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.queueDepth = 3
            config.showsCursor = true
            let stream = SCStream(filter: SCContentFilter(display: target, excludingWindows: []),
                                  configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            if settings.sourceUUID == nil { touchInput = TouchInput(display: captureID) }
            print("已开始采集虚拟显示器 \(target.displayID)")
        }

        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
                    kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let result = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard result == noErr, let session else { throw PrototypeError(tr("Hardware H.264 encoder initialization failed: %d", arguments: [result])) }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel),
            (kVTCompressionPropertyKey_ExpectedFrameRate, fps as NSNumber),
            (kVTCompressionPropertyKey_AverageBitRate, settings.quality.bitrate as NSNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, fps as NSNumber)
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr { print("编码器未接受设置 \(key)：\(status)") }
        }
        let prepare = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepare == noErr else { throw PrototypeError(tr("Encoder preparation failed: %d", arguments: [prepare])) }
        encoder = session
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopping else { return }
            if case .ready = state { self.report("\(tr("Waiting for tablet")) · \(self.settings.summary)") }
            if case .failed(let error) = state {
                DispatchQueue.main.async { [weak self] in
                    self?.onFailure?(tr("Video port unavailable: %@", arguments: [error.localizedDescription]))
                }
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        connectionDeadline = nowMicros() + 12_000_000
        listener.start(queue: queue)
        usbReconnect = USBReconnect.installed(targetID: targetDeviceID, hostPort: hostPort,
                                              inputToken: touchInput == nil ? nil : String(inputToken),
                                              requiredTransport: usbTransport,
                                              log: { [weak self] message in self?.report(message) },
                                              onMissing: { [weak self] in
            queue.async { [weak self] in
                guard let self, !self.stopping else { return }
                if let client = self.connection { self.disconnect(client) }
                if self.usbTransport != nil { self.failConnection(tr("USB tablet disconnected. Sharing stopped.")) }
            }
        })
        usbReconnect?.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: testPattern ? .nanoseconds(1_000_000_000 / fps) : .milliseconds(300))
        timer.setEventHandler { [weak self] in
            if let self, let deadline = self.connectionDeadline {
                let now = nowMicros()
                if let ready = self.clientReadyAt, now - ready >= 1_000_000 {
                    self.connectionDeadline = nil
                } else if now >= deadline {
                    self.failConnection(tr("The tablet did not establish a video connection in time."))
                }
            }
            if let self, let last = self.lastAckAt, nowMicros() - last > 2_000_000 {
                self.lastAckAt = nil
                self.ackWindowStart = nil
                self.measuredFPS = nil
                DispatchQueue.main.async { self.onMetrics?(.init(acknowledgedFPS: nil, latencyMedian: nil, latencyP95: nil)) }
            }
            guard let self, let client = self.connection, self.clientReady, !self.sending else { return }
            if testPattern {
                if !self.encoding, let pixel = self.testFrame() { self.submit(pixel) }
            } else if !self.encoding {
                if self.needsKeyFrame, let latest = self.latestFrame { self.submit(latest) }
                else if !self.needsKeyFrame { self.write(Data(repeating: 0, count: 4), to: client) }
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopping = true
                self.clientReady = false
                self.timer?.cancel()
                self.timer = nil
                self.touchInput?.release()
                self.listener.cancel()
                self.connection?.cancel()
                self.connection = nil
                if let encoder = self.encoder { VTCompressionSessionInvalidate(encoder) }
                self.encoder = nil
                self.latestFrame = nil
                continuation.resume()
            }
        }
        if let stream { try? await stream.stopCapture() }
        stream = nil
        layoutMemory = nil
        display = nil
        if let usbReconnect { await usbReconnect.stop() }
        usbReconnect = nil
    }

    private func accept(_ client: NWConnection) {
        guard !stopping, !connectionFailed else { client.cancel(); return }
        touchInput?.release()
        connection?.cancel()
        connection = client
        hasFirstTokenHalf = false
        inputAuthorized = false
        clientReadyAt = nil
        clientReady = false
        needsKeyFrame = true
        sending = false
        frames = 0
        lastAckAt = nil
        ackWindowStart = nil
        acknowledgedFrames = 0
        measuredFPS = nil
        captureCount = 0
        latencySamples.removeAll(keepingCapacity: true)
        encodingSamples.removeAll(keepingCapacity: true)
        client.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client, self.connection === client else { return }
            switch state {
            case .ready:
                var header = Data("WTS2".utf8)
                header.push(UInt32(width))
                header.push(UInt32(height))
                header.push(UInt32(fps))
                self.clientReady = true
                self.clientReadyAt = nowMicros()
                self.write(header, to: client)
                self.readRenderAck(client)
                self.report("\(tr("Connected")) · \(self.settings.summary)")
            case .cancelled, .failed:
                self.disconnect(client)
            default: break
            }
        }
        client.start(queue: queue)
    }

    private func readRenderAck(_ client: NWConnection) {
        client.receive(minimumIncompleteLength: 8, maximumLength: 8) { [weak self, weak client] data, _, finished, error in
            guard let self, let client, self.connection === client else { return }
            if finished || error != nil { self.disconnect(client); return }
            if let data, data.count == 8 {
                let pts = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                if pts >> 63 != 0 {
                    self.readInputWord(pts)
                    self.readRenderAck(client)
                    return
                }
                let now = nowMicros()
                self.lastAckAt = now
                if let start = self.ackWindowStart {
                    self.acknowledgedFrames += 10
                    if now - start >= 2_000_000 {
                        self.measuredFPS = Double(self.acknowledgedFrames) * 1_000_000 / Double(now - start)
                        self.acknowledgedFrames = 0
                        self.ackWindowStart = now
                        let measured = self.measuredFPS
                        DispatchQueue.main.async { [weak self] in
                            self?.onMetrics?(.init(acknowledgedFPS: measured, latencyMedian: nil, latencyP95: nil))
                        }
                    }
                } else { self.ackWindowStart = now }
                if pts <= now, now - pts < 5_000_000 {
                    self.latencySamples.append(Double(now - pts) / 1_000)
                    if self.latencySamples.count == 60 {
                        let samples = self.latencySamples.sorted()
                        print(String(format: "采集回调→平板渲染回执 (%d 帧样本)：p50 %.1f ms，p95 %.1f ms",
                                     samples.count, samples[29], samples[56]))
                        let measured = self.measuredFPS
                        DispatchQueue.main.async { [weak self] in
                            self?.onMetrics?(.init(acknowledgedFPS: measured, latencyMedian: samples[29], latencyP95: samples[56]))
                        }
                        self.latencySamples.removeAll(keepingCapacity: true)
                    }
                }
            }
            self.readRenderAck(client)
        }
    }

    private func readInputWord(_ word: UInt64) {
        guard let touchInput else { return }
        let payload = word & 0x00ff_ffff_ffff_ffff
        switch (word >> 56) & 0x7f {
        case 6:
            hasFirstTokenHalf = UInt64(inputToken.prefix(14), radix: 16) == payload
            inputAuthorized = false
            touchInput.release()
        case 7:
            inputAuthorized = hasFirstTokenHalf && UInt64(inputToken.suffix(14), radix: 16) == payload
            hasFirstTokenHalf = false
            touchLog.notice("Input session authentication accepted: \(self.inputAuthorized, privacy: .public)")
            if !inputAuthorized { touchInput.release() }
        default:
            if inputAuthorized { touchInput.handle(word) }
        }
    }

    private func failConnection(_ message: String) {
        guard !connectionFailed else { return }
        connectionFailed = true
        if let client = connection { disconnect(client) }
        connectionDeadline = nil
        touchInput?.release()
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
    }

    private func disconnect(_ client: NWConnection) {
        guard connection === client else { return }
        touchInput?.release()
        connection = nil
        clientReadyAt = nil
        clientReady = false
        if !stopping, connectionDeadline == nil { connectionDeadline = nowMicros() + 5_000_000 }
        client.cancel()
        report(tr("Waiting for tablet"))
        DispatchQueue.main.async { [weak self] in self?.onMetrics?(.init(acknowledgedFPS: nil, latencyMedian: nil, latencyP95: nil)) }
    }

    private func write(_ payload: Data, to client: NWConnection) {
        sending = true
        client.send(content: payload, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, self.connection === client else { return }
            self.sending = false
            if error != nil { self.disconnect(client) }
        })
    }

    private var latestFrame: CVPixelBuffer?

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let captureTime = nowMicros()
        guard !stopping, type == .screen, let pixel = buffer.imageBuffer, buffer.isValid else { return }
        let metadata = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        guard let raw = metadata?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if clientReady, connection != nil { captureCount += 1 }
        latestFrame = pixel
        submit(pixel, at: captureTime)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            DispatchQueue.main.async { self.onFailure?(tr("Screen capture stopped: %@", arguments: [error.localizedDescription])) }
        }
    }

    private func submit(_ pixel: CVPixelBuffer, at captureTime: UInt64 = nowMicros()) {
        guard !stopping, let encoder, let client = connection, clientReady, !encoding, !sending else { return }
        let pts = CMTime(value: Int64(captureTime), timescale: 1_000_000)
        let force: CFDictionary? = needsKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        encoding = true
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixel, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: Int32(fps)), frameProperties: force, infoFlagsOut: nil) {
                [weak self, weak client] status, _, sample in
                queue.async {
                    guard let self else { return }
                    self.encoding = false
                    guard !self.stopping, let client, self.connection === client, status == noErr, let sample else { return }
                    self.encodingSamples.append(Double(nowMicros() - captureTime) / 1_000)
                    self.send(sample, pts: UInt64(pts.value), to: client)
                }
            }
        if status != noErr {
            encoding = false
            print("编码失败：\(status)")
            disconnect(client)
        }
    }

    private func send(_ sample: CMSampleBuffer, pts: UInt64, to client: NWConnection) {
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first
        let keyFrame = !(attachments?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let startCode: [UInt8] = [0, 0, 0, 1]
        guard let format = sample.formatDescription, let block = sample.dataBuffer else { disconnect(client); return }
        var count = 0, header: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                   parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count,
                   nalUnitHeaderLengthOut: &header) == noErr, header == 4 else { disconnect(client); return }
        var payload = Data()
        if needsKeyFrame {
            guard keyFrame else { return }
            var decoderConfig = Data()
            for index in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var len = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &len,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr else { disconnect(client); return }
                decoderConfig.append(contentsOf: startCode)
                decoderConfig.append(ptr, count: len)
            }
            appendFrame(decoderConfig, pts: pts, flags: 2, to: &payload)
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length >= 4, length <= 4 * 1024 * 1024 else { disconnect(client); return }
        var frame = Data(count: length)
        let status = frame.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        guard status == noErr else { disconnect(client); return }
        var offset = 0
        while offset + 4 <= length {
            let size = frame[offset..<(offset+4)].reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size <= length - offset - 4 else { disconnect(client); return }
            frame.replaceSubrange(offset..<(offset+4), with: startCode)
            offset += size + 4
        }
        guard offset == length else { disconnect(client); return }
        appendFrame(frame, pts: pts, flags: keyFrame ? 1 : 0, to: &payload)
        needsKeyFrame = false
        frames += 1
        if frames == 1 || frames.isMultiple(of: 120) {
            let samples = encodingSamples.sorted()
            let encode = samples.isEmpty ? 0 : samples[samples.count / 2]
            print(String(format: "已发送 %d 帧，采集 %d 帧，编码回调中位 %.1f ms", frames, captureCount, encode))
            encodingSamples.removeAll(keepingCapacity: true)
        }
        write(payload, to: client)
    }

    private func appendFrame(_ frame: Data, pts: UInt64, flags: UInt32, to packet: inout Data) {
        packet.push(UInt32(frame.count))
        packet.push(pts)
        packet.push(flags)
        packet.append(frame)
    }

    private var tick = 0
    private func testFrame() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let colors: [UInt32] = [0xffdddddd, 0xffe4d52b, 0xff4ccba2, 0xff34a858, 0xffae4ec4, 0xffd64b48, 0xff4c5ad6]
        let step = width / colors.count
        let x = tick * 18 % (width - 130)
        tick = (tick + 1) % (width - 130)
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
            if y < height * 3 / 4 {
                for (i, color) in colors.enumerated() {
                    var fill = color
                    let end = i == colors.count - 1 ? width : (i + 1) * step
                    memset_pattern4(row.advanced(by: i * step * 4), &fill, (end - i * step) * 4)
                }
            } else {
                var bg: UInt32 = 0xff161616, marker: UInt32 = 0xffffffff
                memset_pattern4(row, &bg, width * 4)
                if y > height * 4 / 5 && y < height * 19 / 20 {
                    memset_pattern4(row.advanced(by: x * 4), &marker, 130 * 4)
                }
            }
        }
        return buffer
    }
}

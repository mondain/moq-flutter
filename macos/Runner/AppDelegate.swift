import Cocoa
import FlutterMacOS
import AVFoundation

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Register native capture plugin
    let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
    if let registrar = controller?.registrar(forPlugin: "NativeCapturePlugin") {
      NativeCapturePlugin.register(with: registrar)
    }
  }
}

// MARK: - Native Capture Plugin

/// Native audio/video capture plugin for macOS using AVFoundation
public class NativeCapturePlugin: NSObject, FlutterPlugin {
    private var methodChannel: FlutterMethodChannel?
    private var audioEventChannel: FlutterEventChannel?
    private var videoEventChannel: FlutterEventChannel?

    private var audioStreamHandler: MacOSAudioStreamHandler?
    private var videoStreamHandler: MacOSVideoStreamHandler?

    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var videoOutput: AVCaptureVideoDataOutput?

    private var audioDevice: AVCaptureDevice?
    private var videoDevice: AVCaptureDevice?

    private let captureQueue = DispatchQueue(label: "com.moq_flutter.capture", qos: .userInteractive)

    // Configuration
    private var audioSampleRate: Int = 48000
    private var audioChannels: Int = 2
    private var audioBitsPerSample: Int = 16

    private var videoWidth: Int = 1280
    private var videoHeight: Int = 720
    private var videoFrameRate: Int = 30

    // State
    private var isAudioCapturing = false
    private var isVideoCapturing = false
    private var startTimestamp: CMTime?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = NativeCapturePlugin()

        // Method channel
        instance.methodChannel = FlutterMethodChannel(
            name: "com.moq_flutter/native_capture",
            binaryMessenger: registrar.messenger
        )
        registrar.addMethodCallDelegate(instance, channel: instance.methodChannel!)

        // Audio event channel with dedicated stream handler
        instance.audioStreamHandler = MacOSAudioStreamHandler()
        instance.audioEventChannel = FlutterEventChannel(
            name: "com.moq_flutter/audio_samples",
            binaryMessenger: registrar.messenger
        )
        instance.audioEventChannel?.setStreamHandler(instance.audioStreamHandler)

        // Video event channel with dedicated stream handler
        instance.videoStreamHandler = MacOSVideoStreamHandler()
        instance.videoEventChannel = FlutterEventChannel(
            name: "com.moq_flutter/video_frames",
            binaryMessenger: registrar.messenger
        )
        instance.videoEventChannel?.setStreamHandler(instance.videoStreamHandler)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initializeAudio":
            handleInitializeAudio(call, result: result)
        case "startAudioCapture":
            handleStartAudioCapture(result: result)
        case "stopAudioCapture":
            handleStopAudioCapture(result: result)
        case "initializeVideo":
            handleInitializeVideo(call, result: result)
        case "startVideoCapture":
            handleStartVideoCapture(result: result)
        case "stopVideoCapture":
            handleStopVideoCapture(result: result)
        case "getAvailableCameras":
            handleGetAvailableCameras(result: result)
        case "selectCamera":
            handleSelectCamera(call, result: result)
        case "hasCameraPermission":
            handleHasCameraPermission(result: result)
        case "hasMicrophonePermission":
            handleHasMicrophonePermission(result: result)
        case "requestCameraPermission":
            handleRequestCameraPermission(result: result)
        case "requestMicrophonePermission":
            handleRequestMicrophonePermission(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Audio Methods

    private func handleInitializeAudio(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
            return
        }

        audioSampleRate = args["sampleRate"] as? Int ?? 48000
        audioChannels = args["channels"] as? Int ?? 2
        audioBitsPerSample = args["bitsPerSample"] as? Int ?? 16

        // Initialize capture session if not already
        if captureSession == nil {
            captureSession = AVCaptureSession()
            captureSession?.sessionPreset = .high
        }

        result(nil)
    }

    private func handleStartAudioCapture(result: @escaping FlutterResult) {
        guard !isAudioCapturing else {
            result(nil)
            return
        }

        captureQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                try self.setupAudioCapture()
                self.isAudioCapturing = true
                self.startSessionIfNeeded()
                DispatchQueue.main.async {
                    result(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "AUDIO_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func handleStopAudioCapture(result: @escaping FlutterResult) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }

            self.teardownAudioCapture()
            self.isAudioCapturing = false
            self.stopSessionIfNeeded()

            DispatchQueue.main.async {
                result(nil)
            }
        }
    }

    private func setupAudioCapture() throws {
        guard let session = captureSession else {
            throw CaptureError.sessionNotInitialized
        }

        // Get default audio device
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.noAudioDevice
        }
        audioDevice = device

        // Create input
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()

        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            session.commitConfiguration()
            throw CaptureError.cannotAddInput
        }

        // Create audio output
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
            audioOutput = output
        } else {
            session.commitConfiguration()
            throw CaptureError.cannotAddOutput
        }

        session.commitConfiguration()
    }

    private func teardownAudioCapture() {
        guard let session = captureSession else { return }

        session.beginConfiguration()

        if let output = audioOutput {
            session.removeOutput(output)
            audioOutput = nil
        }

        // Remove audio inputs
        for input in session.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput,
               deviceInput.device.hasMediaType(.audio) {
                session.removeInput(input)
            }
        }

        session.commitConfiguration()
    }

    // MARK: - Video Methods

    private func handleInitializeVideo(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
            return
        }

        videoWidth = args["width"] as? Int ?? 1280
        videoHeight = args["height"] as? Int ?? 720
        videoFrameRate = args["frameRate"] as? Int ?? 30

        // Select camera if specified
        if let cameraId = args["cameraId"] as? String {
            videoDevice = AVCaptureDevice(uniqueID: cameraId)
        }

        // Initialize capture session if not already
        if captureSession == nil {
            captureSession = AVCaptureSession()
            captureSession?.sessionPreset = .high
        }

        result(nil)
    }

    private func handleStartVideoCapture(result: @escaping FlutterResult) {
        guard !isVideoCapturing else {
            result(nil)
            return
        }

        captureQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                try self.setupVideoCapture()
                self.isVideoCapturing = true
                self.startSessionIfNeeded()
                DispatchQueue.main.async {
                    result(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "VIDEO_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func handleStopVideoCapture(result: @escaping FlutterResult) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }

            self.teardownVideoCapture()
            self.isVideoCapturing = false
            self.stopSessionIfNeeded()

            DispatchQueue.main.async {
                result(nil)
            }
        }
    }

    private func setupVideoCapture() throws {
        guard let session = captureSession else {
            throw CaptureError.sessionNotInitialized
        }

        // Get video device
        let device: AVCaptureDevice
        if let selectedDevice = videoDevice {
            device = selectedDevice
        } else if let defaultDevice = AVCaptureDevice.default(for: .video) {
            device = defaultDevice
        } else {
            throw CaptureError.noVideoDevice
        }
        videoDevice = device

        // Configure device
        try device.lockForConfiguration()

        // Set frame rate
        let targetFrameRate = Double(videoFrameRate)
        var bestFormat: AVCaptureDevice.Format?
        var bestFrameRateRange: AVFrameRateRange?

        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                if range.minFrameRate <= targetFrameRate && range.maxFrameRate >= targetFrameRate {
                    if bestFrameRateRange == nil || range.maxFrameRate > bestFrameRateRange!.maxFrameRate {
                        bestFormat = format
                        bestFrameRateRange = range
                    }
                }
            }
        }

        if let format = bestFormat {
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(videoFrameRate))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(videoFrameRate))
        }

        device.unlockForConfiguration()

        // Create input
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()

        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            session.commitConfiguration()
            throw CaptureError.cannotAddInput
        }

        // Create video output
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        output.alwaysDiscardsLateVideoFrames = true

        // Use BGRA format for easier processing
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        if session.canAddOutput(output) {
            session.addOutput(output)
            videoOutput = output
        } else {
            session.commitConfiguration()
            throw CaptureError.cannotAddOutput
        }

        session.commitConfiguration()
    }

    private func teardownVideoCapture() {
        guard let session = captureSession else { return }

        session.beginConfiguration()

        if let output = videoOutput {
            session.removeOutput(output)
            videoOutput = nil
        }

        // Remove video inputs
        for input in session.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput,
               deviceInput.device.hasMediaType(.video) {
                session.removeInput(input)
            }
        }

        session.commitConfiguration()
    }

    private func handleGetAvailableCameras(result: @escaping FlutterResult) {
        var cameras: [[String: Any]] = []

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )

        for device in discoverySession.devices {
            var position: String
            switch device.position {
            case .front:
                position = "front"
            case .back:
                position = "back"
            default:
                position = "external"
            }

            cameras.append([
                "id": device.uniqueID,
                "name": device.localizedName,
                "position": position
            ])
        }

        result(cameras)
    }

    private func handleSelectCamera(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let cameraId = args["cameraId"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
            return
        }

        videoDevice = AVCaptureDevice(uniqueID: cameraId)

        // If currently capturing, restart with new camera
        if isVideoCapturing {
            captureQueue.async { [weak self] in
                guard let self = self else { return }

                self.teardownVideoCapture()
                do {
                    try self.setupVideoCapture()
                    DispatchQueue.main.async {
                        result(nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "CAMERA_ERROR", message: error.localizedDescription, details: nil))
                    }
                }
            }
        } else {
            result(nil)
        }
    }

    // MARK: - Session Management

    private func startSessionIfNeeded() {
        guard let session = captureSession, !session.isRunning else { return }
        startTimestamp = nil
        session.startRunning()
    }

    private func stopSessionIfNeeded() {
        guard let session = captureSession,
              session.isRunning,
              !isAudioCapturing,
              !isVideoCapturing else { return }
        session.stopRunning()
    }

    // MARK: - Permissions

    private func handleHasCameraPermission(result: @escaping FlutterResult) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        result(status == .authorized)
    }

    private func handleHasMicrophonePermission(result: @escaping FlutterResult) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        result(status == .authorized)
    }

    private func handleRequestCameraPermission(result: @escaping FlutterResult) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                result(granted)
            }
        }
    }

    private func handleRequestMicrophonePermission(result: @escaping FlutterResult) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                result(granted)
            }
        }
    }
}

// MARK: - Stream Handlers

class MacOSAudioStreamHandler: NSObject, FlutterStreamHandler {
    var eventSink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}

class MacOSVideoStreamHandler: NSObject, FlutterStreamHandler {
    var eventSink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate & AVCaptureVideoDataOutputSampleBufferDelegate

extension NativeCapturePlugin: AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {

        // Calculate timestamp
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTimestamp == nil {
            startTimestamp = timestamp
        }
        let relativeTime = CMTimeSubtract(timestamp, startTimestamp!)
        let timestampMs = Int(CMTimeGetSeconds(relativeTime) * 1000)

        if output == audioOutput {
            processAudioSampleBuffer(sampleBuffer, timestampMs: timestampMs)
        } else if output == videoOutput {
            processVideoSampleBuffer(sampleBuffer, timestampMs: timestampMs)
        }
    }

    private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestampMs: Int) {
        guard let eventSink = audioStreamHandler?.eventSink else { return }

        // Get audio buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else { return }

        // Copy audio data
        let data = Data(bytes: pointer, count: length)

        // Get format description for sample rate info
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let sampleData: [String: Any] = [
            "data": FlutterStandardTypedData(bytes: data),
            "sampleRate": Int(asbd.pointee.mSampleRate),
            "channels": Int(asbd.pointee.mChannelsPerFrame),
            "bitsPerSample": Int(asbd.pointee.mBitsPerChannel),
            "timestampMs": timestampMs
        ]

        DispatchQueue.main.async {
            eventSink(sampleData)
        }
    }

    private func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestampMs: Int) {
        guard let eventSink = videoStreamHandler?.eventSink else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        // Copy pixel data
        let dataSize = bytesPerRow * height
        let data = Data(bytes: baseAddress, count: dataSize)

        // Determine format string
        let formatString: String
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            formatString = "bgra"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            formatString = "nv12"
        default:
            formatString = "unknown"
        }

        let frameData: [String: Any] = [
            "data": FlutterStandardTypedData(bytes: data),
            "width": width,
            "height": height,
            "format": formatString,
            "bytesPerRow": bytesPerRow,
            "timestampMs": timestampMs
        ]

        DispatchQueue.main.async {
            eventSink(frameData)
        }
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case sessionNotInitialized
    case noAudioDevice
    case noVideoDevice
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .sessionNotInitialized:
            return "Capture session not initialized"
        case .noAudioDevice:
            return "No audio device available"
        case .noVideoDevice:
            return "No video device available"
        case .cannotAddInput:
            return "Cannot add input to capture session"
        case .cannotAddOutput:
            return "Cannot add output to capture session"
        }
    }
}

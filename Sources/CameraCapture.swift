import AVFoundation
import CoreMedia
import CoreVideo

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "com.airgrab.camera", qos: .userInteractive)
    var onFrame: ((CVPixelBuffer) -> Void)?
    private let handlersLock = NSLock()
    private var frameHandlers: [UUID: (CVPixelBuffer) -> Void] = [:]

    static func requestCameraPermission() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            var granted = false
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) { granted = $0; semaphore.signal() }
            semaphore.wait()
            return granted
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start(cameraIndex: Int) throws {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discoverySession.devices
        guard cameraIndex < devices.count else {
            throw CameraCaptureError.cameraNotFound(index: cameraIndex, available: devices.count)
        }
        let device = devices[cameraIndex]

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            throw CameraCaptureError.cannotAddOutput
        }
        session.addOutput(output)

        session.sessionPreset = .medium
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    @discardableResult
    func addFrameHandler(_ handler: @escaping (CVPixelBuffer) -> Void) -> UUID {
        let id = UUID()
        handlersLock.lock()
        frameHandlers[id] = handler
        handlersLock.unlock()
        return id
    }

    func removeFrameHandler(_ id: UUID) {
        handlersLock.lock()
        frameHandlers.removeValue(forKey: id)
        handlersLock.unlock()
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
        handlersLock.lock()
        let handlers = Array(frameHandlers.values)
        handlersLock.unlock()
        for handler in handlers {
            handler(pixelBuffer)
        }
    }
}

enum CameraCaptureError: Error, CustomStringConvertible {
    case cameraNotFound(index: Int, available: Int)
    case cannotAddInput
    case cannotAddOutput

    var description: String {
        switch self {
        case .cameraNotFound(let index, let available):
            return "Camera \(index) not found (available: \(available))"
        case .cannotAddInput:
            return "Cannot add camera input to capture session"
        case .cannotAddOutput:
            return "Cannot add video output to capture session"
        }
    }
}

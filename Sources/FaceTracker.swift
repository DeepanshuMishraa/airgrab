import CoreVideo
import Vision

final class FaceTracker {
    let camera = CameraCapture()
    private let lock = NSLock()
    private var frameHandlerID: UUID?
    private var _latestYaw: Double?
    private var _smoothedYaw: Double?
    private var _latestPitch: Double?
    private var _smoothedPitch: Double?
    private var _latestFaceCenter: CGPoint?
    private var _smoothedFaceCenter: CGPoint?
    private var _latestEyeCenter: CGPoint?
    private var _smoothedEyeCenter: CGPoint?
    private var _frameCount = 0

    private let smoothing: Double = 0.3

    var latestYaw: Double? {
        lock.lock()
        defer { lock.unlock() }
        return _smoothedYaw
    }

    var latestPitch: Double? {
        lock.lock()
        defer { lock.unlock() }
        return _smoothedPitch
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _frameCount
    }

    var latestFaceCenter: CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        return _smoothedFaceCenter
    }

    var latestEyeCenter: CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        return _smoothedEyeCenter
    }

    func start(cameraIndex: Int) throws {
        frameHandlerID = camera.addFrameHandler { [weak self] pixelBuffer in
            self?.processFrame(pixelBuffer)
        }
        try camera.start(cameraIndex: cameraIndex)
    }

    func stop() {
        if let frameHandlerID {
            camera.removeFrameHandler(frameHandlerID)
            self.frameHandlerID = nil
        }
        camera.stop()
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3

        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let face = request.results?.first,
              let yawNumber = face.yaw else {
            lock.lock()
            _latestYaw = nil
            _latestPitch = nil
            _latestFaceCenter = nil
            _latestEyeCenter = nil
            _frameCount += 1
            lock.unlock()
            return
        }

        let yawDegrees = yawNumber.doubleValue * 180.0 / .pi
        let pitchDegrees = face.pitch.map { $0.doubleValue * 180.0 / .pi }
        let faceCenter = CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)
        let eyeCenter = extractEyeCenter(from: face)

        lock.lock()
        _latestYaw = yawDegrees
        if let prev = _smoothedYaw {
            _smoothedYaw = prev + smoothing * (yawDegrees - prev)
        } else {
            _smoothedYaw = yawDegrees
        }
        if let pitch = pitchDegrees {
            if let prev = _smoothedPitch {
                _smoothedPitch = prev + smoothing * (pitch - prev)
            } else {
                _smoothedPitch = pitch
            }
            _latestPitch = pitch
        }
        _latestFaceCenter = faceCenter
        if let prev = _smoothedFaceCenter {
            _smoothedFaceCenter = CGPoint(
                x: prev.x + CGFloat(smoothing) * (faceCenter.x - prev.x),
                y: prev.y + CGFloat(smoothing) * (faceCenter.y - prev.y)
            )
        } else {
            _smoothedFaceCenter = faceCenter
        }
        _latestEyeCenter = eyeCenter
        if let eyeCenter {
            if let prev = _smoothedEyeCenter {
                _smoothedEyeCenter = CGPoint(
                    x: prev.x + CGFloat(smoothing) * (eyeCenter.x - prev.x),
                    y: prev.y + CGFloat(smoothing) * (eyeCenter.y - prev.y)
                )
            } else {
                _smoothedEyeCenter = eyeCenter
            }
        }
        _frameCount += 1
        lock.unlock()
    }

    private func extractEyeCenter(from face: VNFaceObservation) -> CGPoint? {
        guard let landmarks = face.landmarks else { return nil }

        let leftEye = averageLandmarkPoint(landmarks.leftPupil, in: face.boundingBox)
            ?? averageLandmarkPoint(landmarks.leftEye, in: face.boundingBox)
        let rightEye = averageLandmarkPoint(landmarks.rightPupil, in: face.boundingBox)
            ?? averageLandmarkPoint(landmarks.rightEye, in: face.boundingBox)

        guard let leftEye, let rightEye else { return nil }

        return CGPoint(
            x: (leftEye.x + rightEye.x) / 2.0,
            y: (leftEye.y + rightEye.y) / 2.0
        )
    }

    private func averageLandmarkPoint(
        _ region: VNFaceLandmarkRegion2D?,
        in faceBounds: CGRect
    ) -> CGPoint? {
        guard let region, region.pointCount > 0 else { return nil }

        var totalX: CGFloat = 0
        var totalY: CGFloat = 0
        let points = region.normalizedPoints
        for index in 0..<region.pointCount {
            let point = points[index]
            totalX += CGFloat(point.x)
            totalY += CGFloat(point.y)
        }

        let count = CGFloat(region.pointCount)
        let localX = totalX / count
        let localY = totalY / count

        return CGPoint(
            x: faceBounds.minX + faceBounds.width * localX,
            y: faceBounds.minY + faceBounds.height * localY
        )
    }
}

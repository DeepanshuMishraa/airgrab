import Foundation
import Vision

enum HandGesture: Equatable {
    case neutral
    case open
    case pinch
    case fist
    case pinchDistance(Double)
}

struct HandState {
    let position: CGPoint
    let isPinching: Bool
    let isFist: Bool
    let pinchDistance: Double?
}

final class HandTracker {
    private let camera: CameraCapture
    private let lock = NSLock()
    private var frameHandlerID: UUID?
    private var _latestGesture: HandGesture = .neutral
    private var _latestState: HandState?
    private var _handDetected = false
    private var _frameCount = 0

    private let pinchThreshold: Double = 0.08
    private let releasePinchThreshold: Double = 0.11

    var latestGesture: HandGesture {
        lock.lock()
        defer { lock.unlock() }
        return _latestGesture
    }

    var latestState: HandState? {
        lock.lock()
        defer { lock.unlock() }
        return _latestState
    }

    var handDetected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _handDetected
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _frameCount
    }

    init(camera: CameraCapture) {
        self.camera = camera
    }

    func start() {
        guard frameHandlerID == nil else { return }
        frameHandlerID = camera.addFrameHandler { [weak self] pixelBuffer in
            self?.processFrame(pixelBuffer)
        }
    }

    func stop() {
        guard let frameHandlerID else { return }
        camera.removeFrameHandler(frameHandlerID)
        self.frameHandlerID = nil
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        let handPoseRequest = VNDetectHumanHandPoseRequest()
        handPoseRequest.maximumHandCount = 1

        do {
            try handler.perform([handPoseRequest])
        } catch {
            lock.lock()
            _handDetected = false
            _latestState = nil
            _frameCount += 1
            lock.unlock()
            return
        }

        guard let hand = handPoseRequest.results?.first else {
            lock.lock()
            _handDetected = false
            _latestState = nil
            _frameCount += 1
            lock.unlock()
            return
        }

        let gesture = detectGesture(from: hand)
        let handPosition = extractPalmCenter(from: hand)

        var pinchDist: Double? = nil
        var isPinching = false
        if case .pinchDistance(let d) = gesture {
            pinchDist = d
            isPinching = true
        }

        let state = HandState(
            position: handPosition,
            isPinching: isPinching || gesture == .pinch,
            isFist: gesture == .fist,
            pinchDistance: pinchDist
        )

        lock.lock()
        _latestGesture = gesture
        _latestState = state
        _handDetected = true
        _frameCount += 1
        lock.unlock()
    }

    /// Palm-centered normalized point (matches “open palm” pivot); falls back if MCPs are weak.
    private func extractPalmCenter(from hand: VNHumanHandPoseObservation) -> CGPoint {
        guard let wrist = try? hand.recognizedPoint(.wrist), wrist.confidence > 0.25 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        var pts: [CGPoint] = [wrist.location]
        let mcpJoints: [VNHumanHandPoseObservation.JointName] = [
            .indexMCP, .middleMCP, .ringMCP, .littleMCP
        ]
        for joint in mcpJoints {
            if let p = try? hand.recognizedPoint(joint), p.confidence > 0.25 {
                pts.append(p.location)
            }
        }

        if pts.count >= 3 {
            return averagePoint(pts)
        }

        guard let indexTip = try? hand.recognizedPoint(.indexTip), indexTip.confidence > 0.25 else {
            return wrist.location
        }
        return CGPoint(
            x: (indexTip.location.x + wrist.location.x) / 2,
            y: (indexTip.location.y + wrist.location.y) / 2
        )
    }

    private func detectGesture(from hand: VNHumanHandPoseObservation) -> HandGesture {
        guard let thumbTip = try? hand.recognizedPoint(.thumbTip),
              let thumbIP = try? hand.recognizedPoint(.thumbIP),
              let thumbMP = try? hand.recognizedPoint(.thumbMP),
              let indexTip = try? hand.recognizedPoint(.indexTip),
              let indexMCP = try? hand.recognizedPoint(.indexMCP),
              let middleTip = try? hand.recognizedPoint(.middleTip),
              let middleMCP = try? hand.recognizedPoint(.middleMCP),
              let ringTip = try? hand.recognizedPoint(.ringTip),
              let ringMCP = try? hand.recognizedPoint(.ringMCP),
              let pinkyTip = try? hand.recognizedPoint(.littleTip),
              let pinkyMCP = try? hand.recognizedPoint(.littleMCP),
              let wrist = try? hand.recognizedPoint(.wrist),
              thumbTip.confidence > 0.3,
              indexTip.confidence > 0.3,
              middleTip.confidence > 0.3,
              ringTip.confidence > 0.3,
              pinkyTip.confidence > 0.3,
              wrist.confidence > 0.3 else {
            return .neutral
        }

        let palmCenter = averagePoint([
            wrist.location,
            indexMCP.location,
            middleMCP.location,
            ringMCP.location,
            pinkyMCP.location
        ])
        let palmScale = max(
            0.06,
            averageDistance(from: palmCenter, to: [
                wrist.location,
                indexMCP.location,
                middleMCP.location,
                ringMCP.location,
                pinkyMCP.location
            ])
        )

        let indexPinch = distance(indexTip.location, thumbTip.location)
        let middlePinch = distance(middleTip.location, thumbTip.location)
        let ringPinch = distance(ringTip.location, thumbTip.location)
        let pinkyPinch = distance(pinkyTip.location, thumbTip.location)

        let normalizedPinch = indexPinch / palmScale
        let indexExtension = extensionRatio(tip: indexTip.location, base: indexMCP.location, palm: palmCenter)
        let middleExtension = extensionRatio(tip: middleTip.location, base: middleMCP.location, palm: palmCenter)
        let ringExtension = extensionRatio(tip: ringTip.location, base: ringMCP.location, palm: palmCenter)
        let pinkyExtension = extensionRatio(tip: pinkyTip.location, base: pinkyMCP.location, palm: palmCenter)
        let thumbExtension = extensionRatio(tip: thumbTip.location, base: thumbMP.location, palm: palmCenter)

        let extendedCount = [indexExtension, middleExtension, ringExtension, pinkyExtension].filter { $0 >= 1.35 }.count
        let curledCount = [indexExtension, middleExtension, ringExtension, pinkyExtension].filter { $0 <= 1.1 }.count
        let isPinching = normalizedPinch <= 0.42
            && indexPinch < middlePinch * 0.9
            && indexPinch < ringPinch * 0.9
            && indexPinch < pinkyPinch * 0.9

        if isPinching {
            return .pinchDistance(indexPinch)
        }

        if curledCount >= 3 && thumbExtension <= 1.15 && distance(thumbTip.location, thumbIP.location) < palmScale * 0.55 {
            return .fist
        }

        if extendedCount >= 3
            && thumbExtension >= 1.05
            && normalizedPinch >= 0.58
            && average([indexExtension, middleExtension, ringExtension, pinkyExtension]) >= 1.42 {
            return .open
        }

        return .neutral
    }

    private func distance(_ p1: CGPoint, _ p2: CGPoint) -> Double {
        let dx = Double(p1.x - p2.x)
        let dy = Double(p1.y - p2.y)
        return sqrt(dx * dx + dy * dy)
    }

    private func averagePoint(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let total = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: total.x / CGFloat(points.count), y: total.y / CGFloat(points.count))
    }

    private func averageDistance(from point: CGPoint, to points: [CGPoint]) -> Double {
        guard !points.isEmpty else { return 0 }
        let total = points.reduce(0.0) { partial, target in
            partial + distance(point, target)
        }
        return total / Double(points.count)
    }

    private func extensionRatio(tip: CGPoint, base: CGPoint, palm: CGPoint) -> Double {
        let tipDistance = distance(tip, palm)
        let baseDistance = max(distance(base, palm), 0.0001)
        return tipDistance / baseDistance
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

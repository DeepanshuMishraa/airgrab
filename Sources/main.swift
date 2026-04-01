import Foundation
import CoreGraphics
import AppKit

struct Config {
    var calibrate = false
    var calibrateHead = false
    var calibrateHand = false
    var calibrationFile: String
    var cameraIndex = 0
    var verbose = false
    var debug = false

    static let defaultCalibrationPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/share/airgrab/calibration.json"
    }()

    init() {
        calibrationFile = Self.defaultCalibrationPath
    }
}

func parseArgs() -> Config {
    var config = Config()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--calibrate":
            config.calibrate = true
        case "--calibrate-head":
            config.calibrateHead = true
        case "--calibrate-hand":
            config.calibrateHand = true
        case "--calibration-file":
            guard !args.isEmpty else {
                CLI.error("--calibration-file requires a path")
                exit(1)
            }
            config.calibrationFile = args.removeFirst()
        case "--camera":
            guard !args.isEmpty, let idx = Int(args.removeFirst()) else {
                CLI.error("--camera requires an integer")
                exit(1)
            }
            config.cameraIndex = idx
        case "--verbose":
            config.verbose = true
        case "--debug":
            config.debug = true
        case "-v", "--version":
            CLI.printVersion()
            exit(0)
        case "-h", "--help":
            CLI.printUsage()
            exit(0)
        default:
            CLI.error("Unknown argument: \(arg)")
            CLI.printUsage()
            exit(1)
        }
    }
    return config
}

var running = true

func handleSignal(_: Int32) {
    running = false
}

func desktopBounds() -> CGRect {
    NSScreen.screens.reduce(CGRect.null) { partial, screen in
        partial.isNull ? screen.frame : partial.union(screen.frame)
    }
}

func normalizedDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    return sqrt(dx * dx + dy * dy)
}

func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
    Swift.min(Swift.max(value, lower), upper)
}

func gazePointOnMonitor(
    monitorID: Int,
    yaw: Double,
    pitch: Double,
    calibration: [String: GazePoint],
    faceTracker: FaceTracker
) -> CGPoint? {
    guard let calibrationPoint = calibration[String(monitorID)] else { return nil }

    let faceCenter = faceTracker.latestFaceCenter
        ?? CGPoint(x: calibrationPoint.faceX, y: calibrationPoint.faceY)
    let eyeCenter = faceTracker.latestEyeCenter
        ?? CGPoint(x: calibrationPoint.eyeX, y: calibrationPoint.eyeY)

    let eyeDeltaX = CGFloat(eyeCenter.x - calibrationPoint.eyeX)
    let eyeDeltaY = CGFloat(eyeCenter.y - calibrationPoint.eyeY)
    let faceDeltaX = CGFloat(faceCenter.x - calibrationPoint.faceX)
    let faceDeltaY = CGFloat(faceCenter.y - calibrationPoint.faceY)
    let yawDelta = CGFloat(yaw - calibrationPoint.yaw)
    let pitchDelta = CGFloat(pitch - calibrationPoint.pitch)

    let normalizedX = clamp(
        0.5 + eyeDeltaX * 2.6 + faceDeltaX * 1.4 + yawDelta / 18.0,
        min: 0.06,
        max: 0.94
    )
    let normalizedY = clamp(
        0.5 - eyeDeltaY * 2.2 - faceDeltaY * 1.2 - pitchDelta / 16.0,
        min: 0.08,
        max: 0.92
    )

    return CGPoint(x: normalizedX, y: normalizedY)
}

func matchesCalibratedPose(
    current: CGPoint,
    primary: CGPoint,
    secondary: CGPoint,
    tolerance: CGFloat? = nil,
    margin: CGFloat? = nil
) -> Bool {
    let separation = normalizedDistance(primary, secondary)
    let poseTolerance = tolerance ?? min(0.14, max(0.06, separation * 0.65))
    let poseMargin = margin ?? min(0.025, max(0.006, separation * 0.08))
    let primaryDistance = normalizedDistance(current, primary)
    let secondaryDistance = normalizedDistance(current, secondary)
    return primaryDistance <= poseTolerance && primaryDistance + poseMargin < secondaryDistance
}

signal(SIGINT, handleSignal)
signal(SIGTERM, handleSignal)

let config = parseArgs()

CLI.printBanner()

let cameraSpinner = CLI.Spinner("Checking camera permission…")
cameraSpinner.start()

let cameraGranted = CameraCapture.requestCameraPermission()
if !cameraGranted {
    cameraSpinner.fail(finalMessage: "Camera permission denied")
    CLI.info("Please grant camera access in System Settings → Privacy & Security → Camera")
    exit(1)
}

let monitors = MonitorManager.listMonitors()

if monitors.count < 2 {
    cameraSpinner.fail(finalMessage: "Need at least 2 monitors (found \(monitors.count))")
    exit(1)
}
cameraSpinner.stop(finalMessage: "Found \(monitors.count) monitors")

let faceTracker = FaceTracker()
let handTracker = HandTracker(camera: faceTracker.camera)

cameraSpinner.update("Starting camera…")

do {
    try faceTracker.start(cameraIndex: config.cameraIndex)
} catch {
    cameraSpinner.fail(finalMessage: "Cannot open camera \(config.cameraIndex): \(error)")
    exit(1)
}

Thread.sleep(forTimeInterval: 1.0)
cameraSpinner.update("Waiting for frames…")

let initialFrames = faceTracker.frameCount
Thread.sleep(forTimeInterval: 1.0)
if faceTracker.frameCount == initialFrames {
    cameraSpinner.fail(finalMessage: "No frames received from camera")
    CLI.info("Check System Settings → Privacy & Security → Camera")
    faceTracker.stop()
    exit(1)
}
cameraSpinner.stop(finalMessage: "Camera ready")

handTracker.start()

var gazeCalibration: [String: GazePoint]?
if !config.calibrate && !config.calibrateHead {
    gazeCalibration = Calibration.loadGazeCalibration(from: config.calibrationFile)
    if gazeCalibration != nil {
        CLI.success("Loaded head calibration")
    }
}

if gazeCalibration == nil || config.calibrateHead {
    gazeCalibration = Calibration.runGazeCalibration(faceTracker: faceTracker, monitors: monitors)
    if let gc = gazeCalibration {
        Calibration.saveGazeCalibration(gc, to: config.calibrationFile)
    }
}

guard let cal = gazeCalibration else {
    faceTracker.stop()
    CLI.printExit()
    exit(0)
}

var handCalibration: HandCalibrationData?
if !config.calibrate && !config.calibrateHand {
    handCalibration = Calibration.loadHandCalibration(from: config.calibrationFile)
    if handCalibration != nil {
        CLI.success("Loaded hand calibration")
    }
}

if handCalibration == nil || config.calibrateHand {
    handCalibration = Calibration.runHandCalibration(handTracker: handTracker)
    if let hc = handCalibration {
        Calibration.saveHandCalibration(hc, to: config.calibrationFile)
    }
}

guard let handCal = handCalibration else {
    faceTracker.stop()
    CLI.printExit()
    exit(0)
}

let useHandPoseCalibration = normalizedDistance(handCal.grabPosition, handCal.releasePosition) >= 0.09
if !useHandPoseCalibration {
    CLI.warning("Hand grab/release poses are too similar; using gesture-only detection until you recalibrate with more distinct poses.")
}

let microphoneSpinner = CLI.Spinner("Checking microphone permission…")
microphoneSpinner.start()

let microphoneGranted = ClapDetector.requestMicrophonePermission()
if !microphoneGranted {
    microphoneSpinner.fail(finalMessage: "Microphone permission denied")
    CLI.info("Please grant microphone access in System Settings → Privacy & Security → Microphone")
    handTracker.stop()
    faceTracker.stop()
    exit(1)
}
microphoneSpinner.stop(finalMessage: "Microphone ready")

let calSorted = cal.sorted { $0.value.yaw < $1.value.yaw }
let boundaryValues = Calibration.boundaries(from: cal)

let monitorSummary: [(name: String, yaw: Double, pitch: Double)] = calSorted.map { idStr, gaze in
    let name = monitors.first { String($0.id) == idStr }?.name ?? "?"
    return (name: name, yaw: gaze.yaw, pitch: gaze.pitch)
}

CLI.printStartupSummary(monitors: monitorSummary, boundaries: boundaryValues)

let windowManager = WindowManager()
let clapDetector = ClapDetector()

do {
    try clapDetector.start()
    CLI.success("Clap control ready")
    CLI.printActivationStatus(active: false)
} catch {
    CLI.error("Cannot start clap detector: \(error)")
    handTracker.stop()
    faceTracker.stop()
    exit(1)
}

var gazeMonitor = MonitorManager.focusedMonitor() ?? MonitorManager.currentMonitor()
var lastAppliedGazeMonitor = gazeMonitor
let switchCooldown: TimeInterval = 0.5
var lastSwitchTime = Date.distantPast
var lastMonitorTransferTime = Date.distantPast
let monitorTransferCooldown: TimeInterval = 0.3

var isGrabbingWindow = false
var isInteractionActive = false
var pinchFrames = 0
var openFrames = 0
var grabDetected = false
var wasPinchDuringGrab = true
var lastGrabTime = Date.distantPast
var lastReleaseTime = Date.distantPast
let requiredGazeStableFrames = 3
let requiredPinchFrames = 2
let requiredOpenFrames = 2
let grabStabilityThreshold: CGFloat = 0.05
let releaseStabilityThreshold: CGFloat = 0.06
let minimumGrabDuration: TimeInterval = 0.25
let postReleaseCooldown: TimeInterval = 0.2
var lastObservedHandPosition: CGPoint?
var lastObservedGazePoint: CGPoint?
var smoothedGazePoint: CGPoint?
var gazeStableFrames = 0
var gazePointMonitorID: Int?
var pendingMonitorTarget: Int?
var pendingMonitorFrames = 0
let requiredMonitorSwitchFrames = 3

while running {
    if clapDetector.consumeClapEvent() {
        isInteractionActive.toggle()
        pinchFrames = 0
        openFrames = 0
        grabDetected = false
        lastObservedHandPosition = nil
        pendingMonitorTarget = nil
        pendingMonitorFrames = 0

        if isInteractionActive {
            CLI.printGesture("CLAP detected - ACTIVATED")
            CLI.printActivationStatus(active: true)
            WindowHighlight.setColor(grabbed: false)
        } else {
            if isGrabbingWindow {
                windowManager.releaseWindow(targetMonitorID: gazeMonitor)
                isGrabbingWindow = false
                lastReleaseTime = Date()
                WindowHighlight.setColor(grabbed: false)
            } else {
                WindowHighlight.hide()
            }

            wasPinchDuringGrab = true
            CLI.printGesture("CLAP detected - DEACTIVATED")
            CLI.printActivationStatus(active: false)
        }
    }

    var lookedAtPoint: CGPoint?

    if let yaw = faceTracker.latestYaw {
        let pitch = faceTracker.latestPitch ?? 0.0
        let cursorMonitor = MonitorManager.currentMonitor()

        let target = Calibration.targetMonitor(
            yaw: yaw, pitch: pitch,
            calibration: cal,
            currentMonitor: gazeMonitor ?? 0
        )
        gazeMonitor = target
        lookedAtPoint = gazePointOnMonitor(
            monitorID: target,
            yaw: yaw,
            pitch: pitch,
            calibration: cal,
            faceTracker: faceTracker
        )

        if gazePointMonitorID != target {
            // Don't reset gaze stability when grabbing - allows smoother cross-monitor grabs
            if !isGrabbingWindow {
                gazeStableFrames = 0
            }
            lastObservedGazePoint = nil
            smoothedGazePoint = lookedAtPoint
            gazePointMonitorID = target
        }

        if let lookedAtPoint {
            if let lastPoint = lastObservedGazePoint {
                gazeStableFrames = normalizedDistance(lookedAtPoint, lastPoint) <= 0.04
                    ? gazeStableFrames + 1
                    : 0
            }
            lastObservedGazePoint = lookedAtPoint
            if let previous = smoothedGazePoint {
                smoothedGazePoint = CGPoint(
                    x: previous.x + (lookedAtPoint.x - previous.x) * 0.25,
                    y: previous.y + (lookedAtPoint.y - previous.y) * 0.25
                )
            } else {
                smoothedGazePoint = lookedAtPoint
            }
        } else {
            gazeStableFrames = 0
            lastObservedGazePoint = nil
            smoothedGazePoint = nil
        }

        if config.verbose {
            let targetName = monitors.first { $0.id == target }?.name ?? "?"
            let pointText = smoothedGazePoint.map {
                " @ (\(String(format: "%.2f", $0.x)), \(String(format: "%.2f", $0.y)))"
            } ?? ""
            CLI.debug("yaw: \(String(format: "%+.1f", yaw)) pitch: \(String(format: "%+.1f", pitch)) → \(targetName)\(pointText)")
        }

        if gazeMonitor != lastAppliedGazeMonitor {
            if isGrabbingWindow {
                // During grab, just update tracking but don't apply focus transitions
                lastAppliedGazeMonitor = target
            } else {
                let transition = MonitorManager.transition(
                    to: target,
                    cursorMonitor: cursorMonitor
                )

                if transition.requiresAction {
                    let now = Date()
                    if now.timeIntervalSince(lastSwitchTime) >= switchCooldown {
                        MonitorManager.focusMonitor(target, transition: transition, debug: config.debug)
                        lastAppliedGazeMonitor = target
                        lastSwitchTime = now
                    }
                } else {
                    lastAppliedGazeMonitor = target
                }
            }
        }
    }

    let handDetected = handTracker.handDetected

    if handDetected && (isInteractionActive || isGrabbingWindow) {
        let gesture = handTracker.latestGesture
        let handState = handTracker.latestState

        if let currentHandPos = handState?.position {
            let handMotion = lastObservedHandPosition.map { normalizedDistance(currentHandPos, $0) } ?? 0.0
            lastObservedHandPosition = currentHandPos

            let isPinchGesture: Bool
            let isOpenGesture: Bool
            switch gesture {
            case .pinch, .pinchDistance:
                isPinchGesture = true
                isOpenGesture = false
            case .open:
                isPinchGesture = false
                isOpenGesture = true
            case .fist, .neutral:
                isPinchGesture = false
                isOpenGesture = false
            }

            let grabPoseReady = matchesCalibratedPose(
                current: currentHandPos,
                primary: handCal.grabPosition,
                secondary: handCal.releasePosition,
                tolerance: 0.11,
                margin: 0.01
            )
            let releasePoseReady = matchesCalibratedPose(
                current: currentHandPos,
                primary: handCal.releasePosition,
                secondary: handCal.grabPosition
            )

            let gazeReady = gazeStableFrames >= requiredGazeStableFrames && smoothedGazePoint != nil
            let releaseCooldownComplete = Date().timeIntervalSince(lastReleaseTime) >= postReleaseCooldown

            if !isGrabbingWindow {
                openFrames = 0

                if isInteractionActive
                    && releaseCooldownComplete
                    && gazeReady
                    && isPinchGesture
                    && handMotion <= grabStabilityThreshold
                    && (!useHandPoseCalibration || grabPoseReady || normalizedDistance(currentHandPos, handCal.grabPosition) <= 0.13) {
                    pinchFrames += 1
                } else {
                    pinchFrames = 0
                    grabDetected = false
                }

                if pinchFrames >= requiredPinchFrames {
                    let targetMonitor = gazeMonitor ?? MonitorManager.currentMonitor()

                    if let targetMonitor,
                       let smoothedGazePoint,
                       windowManager.grabWindow(
                        onMonitor: targetMonitor,
                        handPosition: currentHandPos,
                        gazePosition: smoothedGazePoint
                       ) {
                        if !grabDetected {
                            CLI.printGesture("GRAB detected")
                            grabDetected = true
                        }
                        isGrabbingWindow = true
                        wasPinchDuringGrab = true
                        pinchFrames = 0
                        lastGrabTime = Date()
                        if config.debug {
                            let targetName = monitors.first { $0.id == targetMonitor }?.name ?? "\(targetMonitor)"
                            CLI.debug("Window on \(targetName) attached to hand via gaze target")
                        }
                        WindowHighlight.setColor(grabbed: true)
                    } else {
                        if !grabDetected {
                            grabDetected = true
                            let targetName = targetMonitor.flatMap { id in
                                monitors.first { $0.id == id }?.name ?? "\(id)"
                            } ?? "unknown monitor"
                            let gazeText = smoothedGazePoint.map {
                                " at gaze (\(String(format: "%.2f", $0.x)), \(String(format: "%.2f", $0.y)))"
                            } ?? ""
                            CLI.warning("Grab pose matched, but no window was found on \(targetName)\(gazeText)")
                        }
                    }
                }
            } else {
                if isPinchGesture {
                    wasPinchDuringGrab = true
                } else if isOpenGesture, wasPinchDuringGrab {
                    windowManager.resetDragAnchor(handPosition: currentHandPos)
                    wasPinchDuringGrab = false
                }

                // Debounce monitor transfers during drag to prevent jittering
                var effectiveTargetMonitor = windowManager.monitorContainingGrabbedWindow()
                if let gazeMonitor, gazeMonitor != effectiveTargetMonitor {
                    if pendingMonitorTarget == gazeMonitor {
                        pendingMonitorFrames += 1
                        if pendingMonitorFrames >= requiredMonitorSwitchFrames {
                            effectiveTargetMonitor = gazeMonitor
                            pendingMonitorTarget = nil
                            pendingMonitorFrames = 0
                        }
                    } else {
                        pendingMonitorTarget = gazeMonitor
                        pendingMonitorFrames = 1
                    }
                } else {
                    pendingMonitorTarget = nil
                    pendingMonitorFrames = 0
                }

                windowManager.moveWindowByHand(
                    handPosition: currentHandPos,
                    targetMonitorID: effectiveTargetMonitor
                )

                if isOpenGesture
                    && Date().timeIntervalSince(lastGrabTime) >= minimumGrabDuration
                    && handMotion <= releaseStabilityThreshold
                    && (!useHandPoseCalibration || releasePoseReady || normalizedDistance(currentHandPos, handCal.releasePosition) <= 0.14) {
                    openFrames += 1
                } else {
                    openFrames = 0
                }

                if openFrames >= requiredOpenFrames {
                    windowManager.releaseWindow(
                        handPosition: currentHandPos,
                        targetMonitorID: gazeMonitor
                    )
                    isGrabbingWindow = false
                    pinchFrames = 0
                    openFrames = 0
                    grabDetected = false
                    pendingMonitorTarget = nil
                    pendingMonitorFrames = 0
                    lastReleaseTime = Date()
                    CLI.printGesture("RELEASE detected")
                    WindowHighlight.setColor(grabbed: false)
                }
            }
        }
    } else {
        lastObservedHandPosition = nil
        if isGrabbingWindow {
            windowManager.releaseWindow(targetMonitorID: gazeMonitor)
            isGrabbingWindow = false
            pinchFrames = 0
            openFrames = 0
            grabDetected = false
            pendingMonitorTarget = nil
            pendingMonitorFrames = 0
            lastReleaseTime = Date()
            CLI.printGesture("HAND lost - released")
            WindowHighlight.setColor(grabbed: false)
        } else {
            pinchFrames = 0
            openFrames = 0
            grabDetected = false
        }
    }

    Thread.sleep(forTimeInterval: 0.033)
}

clapDetector.stop()
handTracker.stop()
faceTracker.stop()
windowManager.releaseWindow(targetMonitorID: gazeMonitor)
WindowHighlight.hide()
CLI.printExit()
exit(0)

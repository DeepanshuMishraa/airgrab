import Foundation

struct GazePoint {
    let yaw: Double
    let pitch: Double
    let faceX: Double
    let faceY: Double
    let eyeX: Double
    let eyeY: Double
}

struct HandCalibrationData {
    let grabPosition: CGPoint
    let releasePosition: CGPoint
}

private enum CalibrationGesture {
    case grab
    case release

    var label: String {
        switch self {
        case .grab:
            return "GRAB"
        case .release:
            return "RELEASE"
        }
    }
}

enum Calibration {
    private static func positionDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Gaze/Monitor Calibration

    static func loadGazeCalibration(from path: String) -> [String: GazePoint]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                CLI.warning("Calibration file is corrupt, will recalibrate")
                return nil
            }
            var result: [String: GazePoint] = [:]
            for (key, value) in dict {
                if let obj = value as? [String: Any],
                   let yaw = obj["yaw"] as? Double,
                   let pitch = obj["pitch"] as? Double {
                    result[key] = GazePoint(
                        yaw: yaw,
                        pitch: pitch,
                        faceX: obj["faceX"] as? Double ?? 0.5,
                        faceY: obj["faceY"] as? Double ?? 0.5,
                        eyeX: obj["eyeX"] as? Double ?? 0.5,
                        eyeY: obj["eyeY"] as? Double ?? 0.5
                    )
                } else if value is Double || value is NSNumber {
                    CLI.warning("Old calibration format, will recalibrate")
                    return nil
                }
            }
            return result.isEmpty ? nil : result
        } catch {
            CLI.warning("Cannot read calibration file: \(error.localizedDescription)")
            return nil
        }
    }

    static func saveGazeCalibration(_ calibration: [String: GazePoint], to path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        var dict: [String: [String: Double]] = [:]
        for (key, point) in calibration {
            dict[key] = [
                "yaw": point.yaw,
                "pitch": point.pitch,
                "faceX": point.faceX,
                "faceY": point.faceY,
                "eyeX": point.eyeX,
                "eyeY": point.eyeY
            ]
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: URL(fileURLWithPath: path))
            CLI.success("Saved calibration")
        } catch {
            CLI.error("Failed to save calibration: \(error)")
        }
    }

    static func sampleGaze(faceTracker: FaceTracker, duration: TimeInterval = 2.0) -> GazePoint? {
        var yawSamples: [Double] = []
        var pitchSamples: [Double] = []
        var faceXSamples: [Double] = []
        var faceYSamples: [Double] = []
        var eyeXSamples: [Double] = []
        var eyeYSamples: [Double] = []
        let start = Date()
        let expectedSamples = Int(duration / 0.033)

        while Date().timeIntervalSince(start) < duration {
            if let yaw = faceTracker.latestYaw {
                yawSamples.append(yaw)
                if let pitch = faceTracker.latestPitch {
                    pitchSamples.append(pitch)
                }
                if let faceCenter = faceTracker.latestFaceCenter {
                    faceXSamples.append(Double(faceCenter.x))
                    faceYSamples.append(Double(faceCenter.y))
                }
                if let eyeCenter = faceTracker.latestEyeCenter {
                    eyeXSamples.append(Double(eyeCenter.x))
                    eyeYSamples.append(Double(eyeCenter.y))
                }
                CLI.printSamplingProgress(
                    yaw: yaw,
                    pitch: faceTracker.latestPitch,
                    sampleCount: yawSamples.count,
                    totalSamples: expectedSamples
                )
            }
            Thread.sleep(forTimeInterval: 0.033)
        }

        print("\(Style.clearLine)\r", terminator: "")
        fflush(stdout)

        guard !yawSamples.isEmpty else { return nil }
        let sortedYaw = yawSamples.sorted()
        let sortedPitch = pitchSamples.sorted()
        let sortedFaceX = faceXSamples.sorted()
        let sortedFaceY = faceYSamples.sorted()
        let sortedEyeX = eyeXSamples.sorted()
        let sortedEyeY = eyeYSamples.sorted()
        let medianYaw = sortedYaw[sortedYaw.count / 2]
        let medianPitch = sortedPitch.isEmpty ? 0.0 : sortedPitch[sortedPitch.count / 2]
        let medianFaceX = sortedFaceX.isEmpty ? 0.5 : sortedFaceX[sortedFaceX.count / 2]
        let medianFaceY = sortedFaceY.isEmpty ? 0.5 : sortedFaceY[sortedFaceY.count / 2]
        let medianEyeX = sortedEyeX.isEmpty ? medianFaceX : sortedEyeX[sortedEyeX.count / 2]
        let medianEyeY = sortedEyeY.isEmpty ? medianFaceY : sortedEyeY[sortedEyeY.count / 2]
        return GazePoint(
            yaw: medianYaw,
            pitch: medianPitch,
            faceX: medianFaceX,
            faceY: medianFaceY,
            eyeX: medianEyeX,
            eyeY: medianEyeY
        )
    }

    static func runGazeCalibration(faceTracker: FaceTracker, monitors: [Monitor]) -> [String: GazePoint]? {
        CLI.printGazeCalibrationHeader(monitorCount: monitors.count)

        var calibration: [String: GazePoint] = [:]

        for (index, m) in monitors.enumerated() {
            ScreenHighlight.show(for: m.id)
            CLI.printGazeCalibrationPrompt(m.name, step: index + 1, total: monitors.count)
            guard readLine() != nil else {
                ScreenHighlight.hide()
                return nil
            }

            var gaze = sampleGaze(faceTracker: faceTracker, duration: 2.0)
            if gaze == nil {
                CLI.warning("No face detected. Try again.")
                CLI.printGazeCalibrationPrompt(m.name, step: index + 1, total: monitors.count)
                guard readLine() != nil else {
                    ScreenHighlight.hide()
                    return nil
                }
                gaze = sampleGaze(faceTracker: faceTracker, duration: 2.0)
                if gaze == nil {
                    CLI.error("Still no face detected. Skipping.")
                    ScreenHighlight.hide()
                    continue
                }
            }

            ScreenHighlight.hide()
            calibration[String(m.id)] = gaze!
            CLI.printGazeCalibrationResult(m.name, yaw: gaze!.yaw, pitch: gaze!.pitch)
        }

        if calibration.count < 2 {
            CLI.error("Need at least 2 calibrated monitors.")
            exit(1)
        }

        let sorted = calibration.sorted { $0.value.yaw < $1.value.yaw }
        let entries: [(name: String, yaw: Double, pitch: Double)] = sorted.map { idStr, gaze in
            let name = monitors.first { String($0.id) == idStr }?.name ?? "?"
            return (name: name, yaw: gaze.yaw, pitch: gaze.pitch)
        }
        CLI.printGazeCalibrationSummary(entries)

        return calibration
    }

    private static let hysteresis = 0.25

    static func targetMonitor(
        yaw: Double, pitch: Double,
        calibration: [String: GazePoint],
        currentMonitor: Int = 0
    ) -> Int {
        guard !calibration.isEmpty else { return 0 }

        let currentKey = String(currentMonitor)
        var bestMonitor = 0
        var bestDistance = Double.infinity

        for (key, point) in calibration {
            let dy = yaw - point.yaw
            let dp = pitch - point.pitch
            var distance = sqrt(dy * dy + dp * dp)

            if key == currentKey {
                distance *= (1.0 - hysteresis)
            }

            if distance < bestDistance {
                bestDistance = distance
                bestMonitor = Int(key) ?? 0
            }
        }

        return bestMonitor
    }

    static func boundaries(from calibration: [String: GazePoint]) -> [Double] {
        let sorted = calibration.sorted { $0.value.yaw < $1.value.yaw }
        var result: [Double] = []
        for i in 0..<(sorted.count - 1) {
            result.append((sorted[i].value.yaw + sorted[i + 1].value.yaw) / 2.0)
        }
        return result
    }

    // MARK: - Hand Gesture Calibration

    private static let recordingDuration: TimeInterval = 6.0

    static func loadHandCalibration(from path: String) -> HandCalibrationData? {
        let handPath = (path as NSString).deletingPathExtension + "_hand.json"
        guard FileManager.default.fileExists(atPath: handPath) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: handPath))
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let grabX = dict["grabX"] as? Double,
                  let grabY = dict["grabY"] as? Double,
                  let releaseX = dict["releaseX"] as? Double,
                  let releaseY = dict["releaseY"] as? Double else {
                return nil
            }
            return HandCalibrationData(
                grabPosition: CGPoint(x: grabX, y: grabY),
                releasePosition: CGPoint(x: releaseX, y: releaseY)
            )
        } catch {
            return nil
        }
    }

    static func saveHandCalibration(_ data: HandCalibrationData, to path: String) {
        let handPath = (path as NSString).deletingPathExtension + "_hand.json"
        let dir = (handPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let dict: [String: Double] = [
            "grabX": Double(data.grabPosition.x),
            "grabY": Double(data.grabPosition.y),
            "releaseX": Double(data.releasePosition.x),
            "releaseY": Double(data.releasePosition.y)
        ]
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
            try jsonData.write(to: URL(fileURLWithPath: handPath))
            CLI.success("Saved hand calibration")
        } catch {
            CLI.error("Failed to save hand calibration: \(error)")
        }
    }

    private static func matchesExpectedGesture(_ gesture: HandGesture, expected: CalibrationGesture) -> Bool {
        switch expected {
        case .grab:
            if case .pinch = gesture { return true }
            if case .pinchDistance = gesture { return true }
            return false
        case .release:
            return gesture == .open
        }
    }

    private static func sampleHandGesture(
        handTracker: HandTracker,
        expectedGesture: CalibrationGesture,
        duration: TimeInterval = recordingDuration
    ) -> (position: CGPoint, sampleCount: Int)? {
        guard waitForStableGesture(handTracker: handTracker, expectedGesture: expectedGesture) else {
            return nil
        }

        var xSamples: [Double] = []
        var ySamples: [Double] = []
        let start = Date()

        while Date().timeIntervalSince(start) < duration {
            if handTracker.handDetected,
               let state = handTracker.latestState,
               matchesExpectedGesture(handTracker.latestGesture, expected: expectedGesture) {
                xSamples.append(Double(state.position.x))
                ySamples.append(Double(state.position.y))
            }
            Thread.sleep(forTimeInterval: 0.033)
        }

        guard !xSamples.isEmpty else { return nil }
        let sortedX = xSamples.sorted()
        let sortedY = ySamples.sorted()
        return (
            CGPoint(
                x: sortedX[sortedX.count / 2],
                y: sortedY[sortedY.count / 2]
            ),
            xSamples.count
        )
    }

    private static func waitForStableGesture(
        handTracker: HandTracker,
        expectedGesture: CalibrationGesture,
        timeout: TimeInterval = 4.0
    ) -> Bool {
        let spinner = CLI.Spinner("Waiting for a steady \(expectedGesture.label.lowercased()) pose…")
        spinner.start()
        defer { spinner.stop() }

        let start = Date()
        var matchingFrames = 0
        var lastPosition: CGPoint?

        while Date().timeIntervalSince(start) < timeout {
            if handTracker.handDetected,
               let state = handTracker.latestState,
               matchesExpectedGesture(handTracker.latestGesture, expected: expectedGesture) {
                let motion = lastPosition.map { positionDistance($0, state.position) } ?? 0
                lastPosition = state.position

                if motion <= 0.03 {
                    matchingFrames += 1
                } else {
                    matchingFrames = 0
                }

                if matchingFrames >= 5 {
                    return true
                }
            } else {
                matchingFrames = 0
                lastPosition = nil
            }

            Thread.sleep(forTimeInterval: 0.033)
        }

        CLI.warning("Could not find a steady \(expectedGesture.label.lowercased()) pose. Try again.")
        return false
    }

    static func runHandCalibration(handTracker: HandTracker) -> HandCalibrationData? {
        CLI.printHandCalibrationHeader()

        CLI.printHandCalibrationPrompt(CalibrationGesture.grab.label)
        CLI.printHandCalibrationInstruction("Get ready to grab the window.")
        CLI.printHandCalibrationInstruction("Press Enter, hold your hand steady, then make and hold a clear thumb-index pinch.")
        guard readLine() != nil else { return nil }

        CLI.printHandCalibrationRecording(gesture: CalibrationGesture.grab.label, duration: recordingDuration)
        guard let grabSample = sampleHandGesture(
            handTracker: handTracker,
            expectedGesture: .grab,
            duration: recordingDuration
        ) else {
            CLI.warning("No grab gesture detected. Try calibration again.")
            return nil
        }
        CLI.printHandCalibrationProcessed(gesture: CalibrationGesture.grab.label, sampleCount: grabSample.sampleCount)

        CLI.printHandCalibrationPrompt(CalibrationGesture.release.label)
        CLI.printHandCalibrationInstruction("Get ready to release the window.")
        CLI.printHandCalibrationInstruction("Press Enter, hold your hand steady, then open your palm fully and naturally.")
        guard readLine() != nil else { return nil }

        CLI.printHandCalibrationRecording(gesture: CalibrationGesture.release.label, duration: recordingDuration)
        guard let releaseSample = sampleHandGesture(
            handTracker: handTracker,
            expectedGesture: .release,
            duration: recordingDuration
        ) else {
            CLI.warning("No open-palm release gesture detected. Try calibration again.")
            return nil
        }
        CLI.printHandCalibrationProcessed(gesture: CalibrationGesture.release.label, sampleCount: releaseSample.sampleCount)

        CLI.printHandCalibrationResult(grabPos: grabSample.position, releasePos: releaseSample.position)

        return HandCalibrationData(
            grabPosition: grabSample.position,
            releasePosition: releaseSample.position
        )
    }
}

import Foundation

enum Style {
    static let reset   = "\u{1B}[0m"
    static let bold    = "\u{1B}[1m"
    static let dim     = "\u{1B}[2m"
    static let italic  = "\u{1B}[3m"

    static let red     = "\u{1B}[31m"
    static let green   = "\u{1B}[32m"
    static let yellow  = "\u{1B}[33m"
    static let blue    = "\u{1B}[34m"
    static let magenta = "\u{1B}[35m"
    static let cyan    = "\u{1B}[36m"
    static let white   = "\u{1B}[37m"
    static let gray    = "\u{1B}[90m"

    static let bgCyan  = "\u{1B}[46m"
    static let bgRed   = "\u{1B}[41m"

    static let clearLine = "\u{1B}[2K"
    static let cursorUp  = "\u{1B}[1A"
    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let saveCursor = "\u{1B}[s"
    static let restoreCursor = "\u{1B}[u"
}

enum CLI {

    static func brand(_ text: String) {
        print("\(Style.bold)\(Style.cyan)\(text)\(Style.reset)")
    }

    static func success(_ text: String) {
        print("  \(Style.green)✓\(Style.reset) \(text)")
    }

    static func error(_ text: String) {
        print("  \(Style.red)✗\(Style.reset) \(Style.red)\(text)\(Style.reset)")
    }

    static func warning(_ text: String) {
        print("  \(Style.yellow)!\(Style.reset) \(Style.yellow)\(text)\(Style.reset)")
    }

    static func info(_ text: String) {
        print("  \(Style.dim)\(text)\(Style.reset)")
    }

    static func debug(_ text: String) {
        print("  \(Style.gray)[DBG]\(Style.reset) \(Style.dim)\(text)\(Style.reset)")
    }

    static func label(_ key: String, _ value: String) {
        print("  \(Style.dim)\(key)\(Style.reset) \(value)")
    }

    private static func fg256(_ n: Int) -> String { "\u{1B}[38;5;\(n)m" }

    static func printBanner() {
        let lines = [
            " █████╗ ██████╗  █████╗ ██████╗ ██████╗ ",
            "██╔══██╗██╔══██╗██╔══██╗██╔══██╗██╔══██╗",
            "███████║██████╔╝███████║██████╔╝██████╔╝",
            "██╔══██║██╔══██╗██╔══██║██╔══██╗██╔══██╗",
            "██║  ██║██████╔╝██║  ██║██████╔╝██████╔╝",
            "╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝╚═════╝ ╚═════╝ ",
        ]
        let colors = [116, 109, 73, 67, 66, 59]

        print()
        for (i, line) in lines.enumerated() {
            let color = colors[i % colors.count]
            print("\(fg256(color))\(line)\(Style.reset)")
        }
        print("\(fg256(59))  ─────────────────────────────────────\(Style.reset)")
        print("\(fg256(109))  clap-activated hand gesture window control\(Style.reset)")
        print()
    }

    static func printVersion() {
        print("airgrab \(BuildInfo.version)")
    }

    static func printUsage() {
        printBanner()
        print("""
          \(Style.dim)$\(Style.reset) airgrab [options]

          \(Style.dim)Clap once to activate control. Clap again to deactivate.\(Style.reset)

          \(Style.cyan)--calibrate\(Style.reset)            Force recalibration
          \(Style.cyan)--calibration-file\(Style.reset) F   Path to calibration file
          \(Style.cyan)--camera\(Style.reset) N             Camera index \(Style.dim)(default: 0)\(Style.reset)
          \(Style.cyan)--verbose\(Style.reset)              Print hand position
          \(Style.cyan)--debug\(Style.reset)                Log debug info
          \(Style.cyan)-v, --version\(Style.reset)         Print version
          \(Style.cyan)-h, --help\(Style.reset)             Show this help
        """)
    }

    final class Spinner {
        private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        private var frameIndex = 0
        private let message: String
        private var timer: DispatchSourceTimer?
        private let queue = DispatchQueue(label: "com.airgrab.spinner")
        private var isRunning = false

        init(_ message: String) {
            self.message = message
        }

        func start() {
            isRunning = true
            print(Style.hideCursor, terminator: "")
            fflush(stdout)

            timer = DispatchSource.makeTimerSource(queue: queue)
            timer?.schedule(deadline: .now(), repeating: .milliseconds(80))
            timer?.setEventHandler { [weak self] in
                guard let self = self, self.isRunning else { return }
                let frame = self.frames[self.frameIndex % self.frames.count]
                self.frameIndex += 1
                print("\(Style.clearLine)\r  \(Style.cyan)\(frame)\(Style.reset) \(self.message)", terminator: "")
                fflush(stdout)
            }
            timer?.resume()
        }

        func update(_ newMessage: String) {
            queue.sync { _ = newMessage }
        }

        func stop(finalMessage: String? = nil) {
            isRunning = false
            timer?.cancel()
            timer = nil
            print("\(Style.clearLine)\r", terminator: "")
            if let msg = finalMessage {
                print("  \(Style.green)✓\(Style.reset) \(msg)")
            }
            print(Style.showCursor, terminator: "")
            fflush(stdout)
        }

        func fail(finalMessage: String) {
            isRunning = false
            timer?.cancel()
            timer = nil
            print("\(Style.clearLine)\r", terminator: "")
            print("  \(Style.red)✗\(Style.reset) \(Style.red)\(finalMessage)\(Style.reset)")
            print(Style.showCursor, terminator: "")
            fflush(stdout)
        }
    }

    static func printGesture(_ action: String) {
        print("\(Style.clearLine)\r  \(Style.magenta)✋\(Style.reset) \(Style.bold)\(action)\(Style.reset)")
    }

    static func printActivationStatus(active: Bool) {
        let stateColor = active ? Style.green : Style.yellow
        let stateText = active ? "ACTIVE" : "INACTIVE"
        let hint = active ? "Clap to deactivate" : "Clap to activate"
        print("  \(Style.cyan)◉\(Style.reset) Status: \(stateColor)\(Style.bold)\(stateText)\(Style.reset)  \(Style.dim)\(hint)\(Style.reset)")
    }

    static func printHandCalibrationHeader() {
        print()
        print("  \(Style.bold)\(Style.yellow)◆ Hand Gesture Calibration\(Style.reset)")
        print("  \(Style.dim)Calibrate grab and release gestures\(Style.reset)")
        print()
    }

    static func printHandCalibrationPrompt(_ gesture: String) {
        print("  \(Style.bold)\(Style.cyan)Step: \(gesture)\(Style.reset)")
    }

    static func printHandCalibrationInstruction(_ text: String) {
        print("  \(Style.dim)\(text)\(Style.reset)")
    }

    static func printHandCalibrationRecording(gesture: String, duration: TimeInterval) {
        print("  \(Style.dim)Recording \(gesture.lowercased()) for \(Int(duration))s… perform it naturally in view of the camera.\(Style.reset)")
    }

    static func printHandCalibrationProcessed(gesture: String, sampleCount: Int) {
        print("  \(Style.green)✓\(Style.reset) Processed \(sampleCount) matching \(gesture.lowercased()) frames")
    }

    static func printHandCalibrationResult(grabPos: CGPoint, releasePos: CGPoint) {
        print("  \(Style.green)✓\(Style.reset) Grab: (\(String(format: "%.2f", grabPos.x)), \(String(format: "%.2f", grabPos.y)))")
        print("  \(Style.green)✓\(Style.reset) Release: (\(String(format: "%.2f", releasePos.x)), \(String(format: "%.2f", releasePos.y)))")
    }

    // MARK: - Monitor/Gaze Calibration

    static func printGazeCalibrationHeader(monitorCount: Int) {
        print()
        print("  \(Style.bold)\(Style.yellow)◆ Monitor Calibration\(Style.reset)")
        print("  \(Style.dim)Found \(monitorCount) monitors\(Style.reset)")
        print()
    }

    static func printGazeCalibrationPrompt(_ monitorName: String, step: Int, total: Int) {
        print("  \(Style.dim)[\(step)/\(total)]\(Style.reset) Look at \(Style.bold)\(monitorName)\(Style.reset), press \(Style.cyan)Enter\(Style.reset), and keep looking for \(Style.bold)2s\(Style.reset)")
    }

    static func printGazeCalibrationResult(_ monitorName: String, yaw: Double, pitch: Double) {
        let yawStr = String(format: "%+.1f°", yaw)
        let pitchStr = String(format: "%+.1f°", pitch)
        print("  \(Style.green)✓\(Style.reset) \(Style.bold)\(monitorName)\(Style.reset)  \(Style.dim)yaw\(Style.reset) \(Style.cyan)\(yawStr)\(Style.reset)  \(Style.dim)pitch\(Style.reset) \(Style.cyan)\(pitchStr)\(Style.reset)")
    }

    static func printSamplingProgress(
        yaw: Double,
        pitch: Double?,
        sampleCount: Int,
        totalSamples: Int
    ) {
        let yawStr = String(format: "%+.1f°", yaw)
        let pitchStr = pitch.map { String(format: "%+.1f°", $0) } ?? "--"
        let progress = min(max(Double(sampleCount) / Double(max(totalSamples, 1)), 0.0), 1.0)
        let filled = Int(progress * 18.0)
        let bar = String(repeating: "=", count: filled) + String(repeating: " ", count: max(0, 18 - filled))
        print(
            "\(Style.clearLine)\r  \(Style.dim)[\(bar)]\(Style.reset) yaw \(Style.cyan)\(yawStr)\(Style.reset) pitch \(Style.cyan)\(pitchStr)\(Style.reset) \(Style.dim)\(sampleCount)/\(totalSamples)\(Style.reset)",
            terminator: ""
        )
        fflush(stdout)
    }

    static func printGazeCalibrationSummary(_ entries: [(name: String, yaw: Double, pitch: Double)]) {
        print()
        print("  \(Style.bold)\(Style.green)✓ Monitor calibration complete\(Style.reset)")
        print()
        for entry in entries {
            let yawStr = String(format: "%+.1f°", entry.yaw)
            let pitchStr = String(format: "%+.1f°", entry.pitch)
            print("    \(Style.bold)\(entry.name)\(Style.reset)  \(Style.dim)yaw\(Style.reset) \(Style.cyan)\(yawStr)\(Style.reset)  \(Style.dim)pitch\(Style.reset) \(Style.cyan)\(pitchStr)\(Style.reset)")
        }
        print()
    }

    static func printStartupSummary(monitors: [(name: String, yaw: Double, pitch: Double)], boundaries: [Double]) {
        print()
        print("  \(Style.bold)Monitors\(Style.reset)")
        for m in monitors {
            let yawStr = String(format: "%+.1f°", m.yaw)
            let pitchStr = String(format: "%+.1f°", m.pitch)
            print("    \(Style.cyan)●\(Style.reset) \(Style.bold)\(m.name)\(Style.reset)  \(Style.dim)yaw \(yawStr)  pitch \(pitchStr)\(Style.reset)")
        }
        print()
        let bStr = boundaries.map { String(format: "%+.1f°", $0) }.joined(separator: "  ")
        print("  \(Style.dim)boundaries  \(bStr)\(Style.reset)")
        print()
        print("  \(Style.dim)Look at a monitor and a window to target it.\(Style.reset)")
        print("  \(Style.dim)Pinch to grab the looked-at window, move hand to drag.\(Style.reset)")
        print("  \(Style.dim)Open your palm again and hold briefly to release.\(Style.reset)")
        print("  \(Style.dim)Press \(Style.reset)Ctrl+C\(Style.dim) to quit.\(Style.reset)")
        print()
    }

    static func printExit() {
        print("\(Style.clearLine)\r")
        print("  \(Style.dim)Stopped.\(Style.reset)")
        print(Style.showCursor, terminator: "")
        fflush(stdout)
    }
}

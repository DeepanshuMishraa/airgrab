import AVFoundation
import Foundation

final class ClapDetector {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var clapPending = false
    private var lastClapTime = Date.distantPast
    private var noiseFloor: Float = 0.01
    private var warmedUpAt = Date()

    static func requestMicrophonePermission() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            var granted = false
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { granted = $0; semaphore.signal() }
            semaphore.wait()
            return granted
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start() throws {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        warmedUpAt = Date()
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func consumeClapEvent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let pending = clapPending
        clapPending = false
        return pending
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard Date().timeIntervalSince(warmedUpAt) >= 0.35,
              let channelData = buffer.floatChannelData else {
            return
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return }

        var sumSquares: Float = 0
        var peak: Float = 0
        let sampleCount = frameLength * channelCount

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for index in 0..<frameLength {
                let value = abs(samples[index])
                sumSquares += value * value
                peak = max(peak, value)
            }
        }

        let rms = sqrt(sumSquares / Float(sampleCount))
        let updatedNoiseFloor = min(max(noiseFloor * 0.985 + rms * 0.015, 0.004), 0.08)
        let effectiveNoiseFloor = max(updatedNoiseFloor, 0.006)
        let impulseRatio = peak / max(rms, 0.0001)
        let spikeRatio = peak / effectiveNoiseFloor

        noiseFloor = rms < peak * 0.72 ? updatedNoiseFloor : min(noiseFloor * 0.998 + rms * 0.002, 0.08)

        guard peak >= max(0.20, effectiveNoiseFloor * 6.5),
              rms >= max(0.015, effectiveNoiseFloor * 1.15),
              impulseRatio >= 3.2,
              spikeRatio >= 8.0 else {
            return
        }

        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSince(lastClapTime) >= 1.0 else { return }
        lastClapTime = now
        clapPending = true
    }
}

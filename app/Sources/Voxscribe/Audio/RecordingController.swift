import AVFoundation
import Foundation

@MainActor
final class RecordingController: NSObject, ObservableObject {
    enum PermissionState: String {
        case unknown
        case granted
        case denied
    }

    enum RecordingError: LocalizedError {
        case permissionDenied
        case recorderUnavailable
        case startFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone permission is required to record."
            case .recorderUnavailable:
                return "Unable to initialize audio recorder."
            case .startFailed:
                return "Could not start recording."
            }
        }
    }

    @Published private(set) var permissionState: PermissionState = .unknown
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var meterLevels: [Double] = Array(repeating: 0, count: 16)

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var recordingURL: URL?

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionState = .granted
            return true
        case .denied, .restricted:
            permissionState = .denied
            return false
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            permissionState = granted ? .granted : .denied
            return granted
        @unknown default:
            permissionState = .denied
            return false
        }
    }

    func startRecording(to url: URL) async throws {
        guard await requestPermission() else {
            throw RecordingError.permissionDenied
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw RecordingError.startFailed
        }

        self.recorder = recorder
        self.recordingURL = url
        self.startedAt = Date()
        self.elapsed = 0
        self.isRecording = true
        startMeterTimer()
    }

    @discardableResult
    func stopRecording() -> TimeInterval {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        let finalElapsed = elapsed
        isRecording = false
        recorder = nil
        startedAt = nil
        return finalElapsed
    }

    func cancelRecording(deleteFile: Bool = true) {
        let url = recordingURL
        _ = stopRecording()
        if deleteFile, let url {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
    }

    private func startMeterTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.12, target: self, selector: #selector(handleMeterTimer), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc
    private func handleMeterTimer() {
        guard let recorder else { return }
        recorder.updateMeters()
        if let startedAt {
            elapsed = Date().timeIntervalSince(startedAt)
        }

        let power = recorder.averagePower(forChannel: 0) // -160...0
        let normalized = Double(max(0, min(1, (power + 60) / 60)))
        var levels = meterLevels
        levels.removeFirst()
        levels.append(normalized)
        meterLevels = levels
    }
}

extension RecordingController: AVAudioRecorderDelegate {}

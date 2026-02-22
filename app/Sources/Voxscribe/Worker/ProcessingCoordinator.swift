import Foundation

struct WorkerSetupStatus: Sendable, Equatable {
    var status: String
    var whisperCppAvailable: Bool
    var whisperCppBinaryAvailable: Bool
    var whisperCppTurboModelAvailable: Bool
    var whisperCppBestModelAvailable: Bool
    var pyannoteAvailable: Bool
    var diarizationTokenPresent: Bool
    var missingDependencies: [String]
}

struct ProcessingProgressEvent: Sendable {
    var stage: ProcessingStage
    var progress: Double
    var message: String
}

struct ProcessingJobOutput: Sendable {
    var transcriptPath: String
    var metricsPath: String?
    var exportPaths: [String: String]
    var detectedLanguage: String?
}

struct WorkerWarmupStatus: Sendable, Equatable {
    var status: String
    var durationSec: Double
    var asrOK: Bool
    var diarizationOK: Bool
    var warnings: [String]
}

enum ProcessingCoordinatorError: LocalizedError {
    case workerNotFound(URL)
    case invalidWorkerMessage
    case workerLaunchFailed(String)
    case workerError(code: String, message: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .workerNotFound(let url):
            return "Worker script not found at \(url.path)"
        case .invalidWorkerMessage:
            return "Received an invalid response from the worker."
        case .workerLaunchFailed(let message):
            return "Failed to launch worker: \(message)"
        case .workerError(_, let message):
            return message
        case .cancelled:
            return "Processing was cancelled."
        }
    }

    var code: String {
        switch self {
        case .workerNotFound:
            return "WORKER_LAUNCH_FAILED"
        case .invalidWorkerMessage:
            return "UNKNOWN_PROCESSING_ERROR"
        case .workerLaunchFailed:
            return "WORKER_LAUNCH_FAILED"
        case .workerError(let code, _):
            return code
        case .cancelled:
            return "JOB_CANCELLED"
        }
    }
}

actor ProcessingCoordinator {
    private struct WorkerSessionSignature: Equatable {
        let projectRootPath: String
        let workerScriptPath: String
        let pythonExecutablePath: String
        let diarizationToken: String?
        let whisperCppTuningFingerprint: String?
    }

    private final class WorkerSession: @unchecked Sendable {
        let process: Process
        let stdin: FileHandle
        let stdout: FileHandle
        let stderrBuffer: StderrBuffer
        let signature: WorkerSessionSignature

        init(
            process: Process,
            stdin: FileHandle,
            stdout: FileHandle,
            stderrBuffer: StderrBuffer,
            signature: WorkerSessionSignature
        ) {
            self.process = process
            self.stdin = stdin
            self.stdout = stdout
            self.stderrBuffer = stderrBuffer
            self.signature = signature
        }
    }

    private final class StderrBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func text() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private var activeProcess: Process?
    private var workerSession: WorkerSession?
    private var commandInFlight = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []

    func cancelCurrentJob() {
        activeProcess?.terminate()
        activeProcess = nil
        teardownWorkerSession()
    }

    func validateSetup(projectRoot: URL) async throws -> WorkerSetupStatus {
        try await validateSetup(projectRoot: projectRoot, diarizationToken: nil, workerScriptPath: nil)
    }

    func validateSetup(
        projectRoot: URL,
        diarizationToken: String?,
        workerScriptPath: String?
    ) async throws -> WorkerSetupStatus {
        let response = try await runSingleCommand(
            projectRoot: projectRoot,
            command: "validate_setup",
            payload: [:],
            diarizationToken: diarizationToken,
            workerScriptPath: workerScriptPath,
            whisperCppTuning: nil,
            onProgress: nil
        )
        guard let payload = response["payload"] as? [String: Any] else { throw ProcessingCoordinatorError.invalidWorkerMessage }
        let dependencies = payload["dependencies"] as? [String: Any] ?? [:]
        return WorkerSetupStatus(
            status: payload["status"] as? String ?? "unknown",
            whisperCppAvailable: dependencies["whisperCppAvailable"] as? Bool ?? false,
            whisperCppBinaryAvailable: dependencies["whisperCppBinaryAvailable"] as? Bool ?? false,
            whisperCppTurboModelAvailable: dependencies["whisperCppTurboModelAvailable"] as? Bool ?? false,
            whisperCppBestModelAvailable: dependencies["whisperCppBestModelAvailable"] as? Bool ?? false,
            pyannoteAvailable: dependencies["pyannoteAvailable"] as? Bool ?? false,
            diarizationTokenPresent: payload["diarizationTokenPresent"] as? Bool ?? false,
            missingDependencies: payload["missingDependencies"] as? [String] ?? []
        )
    }

    func runTranscriptionJob(
        projectRoot: URL,
        manifest: SessionManifest,
        audioPath: URL,
        outputDir: URL,
        settings: AppSettings,
        diarizationToken: String?,
        workerScriptPath: String?,
        diarizationOnly: Bool = false,
        transcriptPath: URL? = nil,
        onProgress: (@Sendable (ProcessingProgressEvent) -> Void)?
    ) async throws -> ProcessingJobOutput {
        var payload: [String: Any] = [
            "jobId": UUID().uuidString,
            "sessionId": manifest.id.uuidString,
            "audioPath": audioPath.path,
            "outputDir": outputDir.path,
            "languageMode": manifest.languageMode.rawValue,
            "profile": manifest.profile.rawValue,
            "asrBackend": manifest.modelConfig.asrBackend.rawValue,
            "asrModel": manifest.modelConfig.asrModel,
            "diarizationEnabled": manifest.modelConfig.diarizationEnabled,
            "wordTimestamps": true,
            "mockMode": settings.enableMockPipeline,
            "diarizationOnly": diarizationOnly,
        ]
        if let transcriptPath {
            payload["transcriptPath"] = transcriptPath.path
        }

        let response = try await runSingleCommand(
            projectRoot: projectRoot,
            command: "run_transcription_job",
            payload: payload,
            diarizationToken: diarizationToken,
            workerScriptPath: workerScriptPath,
            whisperCppTuning: settings.whisperCppTuning,
            onProgress: onProgress
        )
        guard let payload = response["payload"] as? [String: Any] else { throw ProcessingCoordinatorError.invalidWorkerMessage }
        let status = payload["status"] as? String ?? "unknown"
        if status == "cancelled" {
            throw ProcessingCoordinatorError.cancelled
        }
        guard status == "completed" else {
            throw ProcessingCoordinatorError.workerError(code: "UNKNOWN_PROCESSING_ERROR", message: "Unexpected worker status: \(status)")
        }
        return ProcessingJobOutput(
            transcriptPath: payload["transcriptPath"] as? String ?? "",
            metricsPath: payload["metricsPath"] as? String,
            exportPaths: payload["exportPaths"] as? [String: String] ?? [:],
            detectedLanguage: payload["detectedLanguage"] as? String
        )
    }

    func warmUpModels(
        projectRoot: URL,
        profile: ProcessingProfile,
        includeDiarization: Bool,
        diarizationToken: String?,
        workerScriptPath: String?
    ) async throws -> WorkerWarmupStatus {
        let response = try await runSingleCommand(
            projectRoot: projectRoot,
            command: "warm_up_models",
            payload: [
                "profile": profile.rawValue,
                "includeDiarization": includeDiarization,
            ],
            diarizationToken: diarizationToken,
            workerScriptPath: workerScriptPath,
            whisperCppTuning: nil,
            onProgress: nil
        )
        guard let payload = response["payload"] as? [String: Any] else { throw ProcessingCoordinatorError.invalidWorkerMessage }
        let asr = payload["asr"] as? [String: Any] ?? [:]
        let diar = payload["diarization"] as? [String: Any] ?? [:]
        return WorkerWarmupStatus(
            status: payload["status"] as? String ?? "unknown",
            durationSec: payload["durationSec"] as? Double ?? 0,
            asrOK: asr["ok"] as? Bool ?? false,
            diarizationOK: diar["ok"] as? Bool ?? false,
            warnings: payload["warnings"] as? [String] ?? []
        )
    }

    private func runSingleCommand(
        projectRoot: URL,
        command: String,
        payload: [String: Any],
        diarizationToken: String?,
        workerScriptPath: String?,
        whisperCppTuning: WhisperCppTuningConfig?,
        onProgress: (@Sendable (ProcessingProgressEvent) -> Void)?
    ) async throws -> [String: Any] {
        await acquireCommandSlot()
        defer { releaseCommandSlot() }

        let workerURL = resolveWorkerScript(projectRoot: projectRoot, workerScriptPathOverride: workerScriptPath)
        guard FileManager.default.fileExists(atPath: workerURL.path) else {
            throw ProcessingCoordinatorError.workerNotFound(workerURL)
        }
        let pythonExecutable = resolvePythonExecutable(projectRoot: projectRoot)
        let session = try ensureWorkerSession(
            projectRoot: projectRoot,
            workerURL: workerURL,
            pythonExecutable: pythonExecutable,
            diarizationToken: diarizationToken,
            whisperCppTuning: whisperCppTuning
        )
        let process = session.process

        let requestId = UUID().uuidString
        var request: [String: Any] = [
            "type": "request",
            "requestId": requestId,
            "command": command,
            "payload": payload,
        ]
        // JSONSerialization wants Foundation types; make sure payload is object-compatible.
        if request["payload"] == nil {
            request["payload"] = [:]
        }

        var finalResponse: [String: Any]?
        var workerError: ProcessingCoordinatorError?
        var parsingError: Error?
        activeProcess = process

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        session.stdin.write(requestData)
        session.stdin.write(Data([0x0A]))

        do {
            for try await line in session.stdout.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                // Some ML dependencies print progress/warnings to stdout. Ignore any non-JSON protocol lines.
                guard trimmed.first == "{" else { continue }
                guard let data = trimmed.data(using: .utf8) else { continue }
                let raw: [String: Any]
                do {
                    guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    raw = parsed
                } catch {
                    continue
                }
                guard let type = raw["type"] as? String else { continue }
                if type == "event",
                   let payload = raw["payload"] as? [String: Any],
                   let event = payload["event"] as? String,
                   event == "job_progress",
                   let stageRaw = payload["stage"] as? String,
                   let stage = Self.stage(from: stageRaw)
                {
                    let progress = payload["progress"] as? Double ?? 0
                    let message = payload["message"] as? String ?? stage.displayLabel
                    onProgress?(ProcessingProgressEvent(stage: stage, progress: progress, message: message))
                    continue
                }

                if type == "error",
                   let payload = raw["payload"] as? [String: Any]
                {
                    let code = payload["code"] as? String ?? "UNKNOWN_PROCESSING_ERROR"
                    let message = payload["message"] as? String ?? "Worker error"
                    workerError = (code == "JOB_CANCELLED") ? .cancelled : .workerError(code: code, message: message)
                    continue
                }

                if type == "response",
                   let responseRequestId = raw["requestId"] as? String,
                   responseRequestId == requestId,
                   let responseCommand = raw["command"] as? String,
                   responseCommand == command,
                   let payload = raw["payload"] as? [String: Any]
                {
                    if let status = payload["status"] as? String, status == "accepted" {
                        continue
                    }
                    finalResponse = raw
                    break
                }
            }
        } catch {
            parsingError = error
        }
        activeProcess = nil

        if let parsingError {
            teardownWorkerSession()
            throw ProcessingCoordinatorError.workerLaunchFailed("stdout parse error: \(parsingError.localizedDescription)")
        }
        if let workerError {
            if !process.isRunning {
                teardownWorkerSession()
            }
            throw workerError
        }
        if let finalResponse {
            return finalResponse
        }

        let stderrText = session.stderrBuffer.text()
        if process.terminationReason == .uncaughtSignal || process.terminationStatus != 0 {
            teardownWorkerSession()
            throw ProcessingCoordinatorError.workerLaunchFailed(stderrText.isEmpty ? "Worker exited with code \(process.terminationStatus)" : stderrText)
        }
        teardownWorkerSession()
        throw ProcessingCoordinatorError.invalidWorkerMessage
    }

    private func acquireCommandSlot() async {
        if !commandInFlight {
            commandInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            commandWaiters.append(continuation)
        }
    }

    private func releaseCommandSlot() {
        if let next = commandWaiters.first {
            commandWaiters.removeFirst()
            next.resume()
        } else {
            commandInFlight = false
        }
    }

    private func ensureWorkerSession(
        projectRoot: URL,
        workerURL: URL,
        pythonExecutable: URL,
        diarizationToken: String?,
        whisperCppTuning: WhisperCppTuningConfig?
    ) throws -> WorkerSession {
        let signature = WorkerSessionSignature(
            projectRootPath: projectRoot.path,
            workerScriptPath: workerURL.path,
            pythonExecutablePath: pythonExecutable.path,
            diarizationToken: diarizationToken?.isEmpty == true ? nil : diarizationToken,
            whisperCppTuningFingerprint: whisperCppTuning.map {
                "\($0.preset.rawValue)|\($0.customThreads.map(String.init) ?? "")|\($0.customBeamSize.map(String.init) ?? "")|\($0.customBestOf.map(String.init) ?? "")"
            }
        )

        if let existing = workerSession, existing.process.isRunning, existing.signature == signature {
            return existing
        }

        teardownWorkerSession()

        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = pythonExecutable
        process.arguments = [workerURL.path]
        process.environment = configuredEnvironment(diarizationToken: diarizationToken, whisperCppTuning: whisperCppTuning)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stderrBuffer = StderrBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.append(chunk)
        }

        do {
            try process.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let session = WorkerSession(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutPipe.fileHandleForReading,
            stderrBuffer: stderrBuffer,
            signature: signature
        )
        workerSession = session
        return session
    }

    private func teardownWorkerSession() {
        guard let session = workerSession else { return }
        session.stdout.readabilityHandler = nil
        if session.process.isRunning {
            session.process.terminate()
        }
        workerSession = nil
    }

    private func resolveWorkerScript(projectRoot: URL, workerScriptPathOverride: String?) -> URL {
        if let workerScriptPathOverride,
           !workerScriptPathOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: workerScriptPathOverride)
        }
        if let resourceURL = Bundle.main.resourceURL {
            let bundledWorker = resourceURL.appendingPathComponent("worker/voxscribe_worker.py")
            if FileManager.default.fileExists(atPath: bundledWorker.path) {
                return bundledWorker
            }
            let flatWorker = resourceURL.appendingPathComponent("voxscribe_worker.py")
            if FileManager.default.fileExists(atPath: flatWorker.path) {
                return flatWorker
            }
        }
        return projectRoot.appendingPathComponent("worker/voxscribe_worker.py")
    }

    private func resolvePythonExecutable(projectRoot: URL) -> URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["VOXSCRIBE_WORKER_PYTHON"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        if let resourceURL = Bundle.main.resourceURL {
            let bundledPython = resourceURL.appendingPathComponent("worker_runtime/bin/python3")
            if fm.fileExists(atPath: bundledPython.path) {
                return bundledPython
            }
        }
        if let installedRuntime = Self.optionalDiarizationRuntimePythonURL(),
           fm.isExecutableFile(atPath: installedRuntime.path)
        {
            return installedRuntime
        }
        let candidates = [
            projectRoot.appendingPathComponent(".venv313/bin/python3"),
            projectRoot.appendingPathComponent(".venv/bin/python3"),
            projectRoot.appendingPathComponent("app/.venv313/bin/python3"),
            projectRoot.appendingPathComponent("app/.venv/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3"),
        ]
        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    private func configuredEnvironment(
        diarizationToken: String?,
        whisperCppTuning: WhisperCppTuningConfig?
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("voxscribe-worker-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true, attributes: nil)
        let matplotlibDir = cacheRoot.appendingPathComponent("matplotlib", isDirectory: true)
        let xdgCacheDir = cacheRoot.appendingPathComponent("xdg-cache", isDirectory: true)
        let huggingFaceDir = cacheRoot.appendingPathComponent("huggingface", isDirectory: true)
        let torchDir = cacheRoot.appendingPathComponent("torch", isDirectory: true)
        try? FileManager.default.createDirectory(at: matplotlibDir, withIntermediateDirectories: true, attributes: nil)
        try? FileManager.default.createDirectory(at: xdgCacheDir, withIntermediateDirectories: true, attributes: nil)
        try? FileManager.default.createDirectory(at: huggingFaceDir, withIntermediateDirectories: true, attributes: nil)
        try? FileManager.default.createDirectory(at: torchDir, withIntermediateDirectories: true, attributes: nil)
        env["MPLCONFIGDIR"] = matplotlibDir.path
        env["XDG_CACHE_HOME"] = xdgCacheDir.path
        env["HF_HOME"] = huggingFaceDir.path
        env["HUGGINGFACE_HUB_CACHE"] = huggingFaceDir.appendingPathComponent("hub", isDirectory: true).path
        env["TORCH_HOME"] = torchDir.path
        if let diarizationToken, !diarizationToken.isEmpty {
            env["HF_TOKEN"] = diarizationToken
            env["HUGGINGFACE_HUB_TOKEN"] = diarizationToken
        }
        if let whisperCppTuning {
            applyWhisperCppTuning(whisperCppTuning, to: &env)
        }
        let fm = FileManager.default
        if let resourceURL = Bundle.main.resourceURL {
            let bundledWhisperCppBin = resourceURL.appendingPathComponent("whispercpp/whisper-cli")
            if fm.isExecutableFile(atPath: bundledWhisperCppBin.path) {
                env["FREEWHISPR_WHISPERCPP_BIN"] = bundledWhisperCppBin.path
            }
            let bundledWhisperCppModels = resourceURL.appendingPathComponent("whispercpp/models", isDirectory: true)
            if fm.fileExists(atPath: bundledWhisperCppModels.path) {
                env["FREEWHISPR_WHISPERCPP_MODEL_DIR"] = bundledWhisperCppModels.path
            }
        }
        return env
    }

    private func applyWhisperCppTuning(_ tuning: WhisperCppTuningConfig, to env: inout [String: String]) {
        func set(_ key: String, _ value: Int?) {
            if let value {
                env[key] = String(value)
            } else {
                env.removeValue(forKey: key)
            }
        }

        switch tuning.preset {
        case .automatic:
            set("FREEWHISPR_WHISPERCPP_THREADS", nil)
            set("FREEWHISPR_WHISPERCPP_BEAM_SIZE", nil)
            set("FREEWHISPR_WHISPERCPP_BEST_OF", nil)
        case .m4ProFast:
            set("FREEWHISPR_WHISPERCPP_THREADS", 12)
            set("FREEWHISPR_WHISPERCPP_BEAM_SIZE", 1)
            set("FREEWHISPR_WHISPERCPP_BEST_OF", 1)
        case .m4ProBalanced:
            set("FREEWHISPR_WHISPERCPP_THREADS", 12)
            set("FREEWHISPR_WHISPERCPP_BEAM_SIZE", 3)
            set("FREEWHISPR_WHISPERCPP_BEST_OF", 3)
        case .m4ProAccuracy:
            set("FREEWHISPR_WHISPERCPP_THREADS", 10)
            set("FREEWHISPR_WHISPERCPP_BEAM_SIZE", 5)
            set("FREEWHISPR_WHISPERCPP_BEST_OF", 5)
        case .custom:
            set("FREEWHISPR_WHISPERCPP_THREADS", tuning.customThreads)
            set("FREEWHISPR_WHISPERCPP_BEAM_SIZE", tuning.customBeamSize)
            set("FREEWHISPR_WHISPERCPP_BEST_OF", tuning.customBestOf)
        }
    }

    static func optionalDiarizationRuntimePythonURL() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport
            .appendingPathComponent("com.jesse.voxscribe", isDirectory: true)
            .appendingPathComponent("worker_runtime_diarization", isDirectory: true)
            .appendingPathComponent("bin/python3")
    }

    static func defaultProjectRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["VOXSCRIBE_PROJECT_ROOT"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if cwd.lastPathComponent == "app" {
            return cwd.deletingLastPathComponent()
        }
        return cwd
    }

    private static func stage(from raw: String) -> ProcessingStage? {
        switch raw {
        case "preparing": return .preparing
        case "transcribing": return .transcribing
        case "diarizing": return .diarizing
        case "reconciling": return .reconciling
        case "writing_output": return .writingOutput
        case "exporting": return .exporting
        default: return nil
        }
    }
}

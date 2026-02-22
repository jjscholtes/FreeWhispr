import Foundation

struct WorkerSetupStatus: Sendable, Equatable {
    var status: String
    var fasterWhisperAvailable: Bool
    var whisperCppAvailable: Bool
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

    func cancelCurrentJob() {
        activeProcess?.terminate()
        activeProcess = nil
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
            onProgress: nil
        )
        guard let payload = response["payload"] as? [String: Any] else { throw ProcessingCoordinatorError.invalidWorkerMessage }
        let dependencies = payload["dependencies"] as? [String: Any] ?? [:]
        return WorkerSetupStatus(
            status: payload["status"] as? String ?? "unknown",
            fasterWhisperAvailable: dependencies["fasterWhisperAvailable"] as? Bool ?? false,
            whisperCppAvailable: dependencies["whisperCppAvailable"] as? Bool ?? false,
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
        onProgress: (@Sendable (ProcessingProgressEvent) -> Void)?
    ) async throws -> ProcessingJobOutput {
        let payload: [String: Any] = [
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
        ]

        let response = try await runSingleCommand(
            projectRoot: projectRoot,
            command: "run_transcription_job",
            payload: payload,
            diarizationToken: diarizationToken,
            workerScriptPath: workerScriptPath,
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

    private func runSingleCommand(
        projectRoot: URL,
        command: String,
        payload: [String: Any],
        diarizationToken: String?,
        workerScriptPath: String?,
        onProgress: (@Sendable (ProcessingProgressEvent) -> Void)?
    ) async throws -> [String: Any] {
        let workerURL = resolveWorkerScript(projectRoot: projectRoot, workerScriptPathOverride: workerScriptPath)
        guard FileManager.default.fileExists(atPath: workerURL.path) else {
            throw ProcessingCoordinatorError.workerNotFound(workerURL)
        }

        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = resolvePythonExecutable(projectRoot: projectRoot)
        process.arguments = [workerURL.path]
        process.environment = configuredEnvironment(diarizationToken: diarizationToken)

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
        defer {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

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

        try process.run()
        activeProcess = process

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        stdinPipe.fileHandleForWriting.write(requestData)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
        stdinPipe.fileHandleForWriting.closeFile()

        do {
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
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
                }
            }
        } catch {
            parsingError = error
        }

        while process.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        activeProcess = nil

        if let parsingError {
            throw ProcessingCoordinatorError.workerLaunchFailed("stdout parse error: \(parsingError.localizedDescription)")
        }
        if let workerError {
            throw workerError
        }
        if let finalResponse {
            return finalResponse
        }

        let stderrText = stderrBuffer.text()
        if process.terminationReason == .uncaughtSignal || process.terminationStatus != 0 {
            throw ProcessingCoordinatorError.workerLaunchFailed(stderrText.isEmpty ? "Worker exited with code \(process.terminationStatus)" : stderrText)
        }
        throw ProcessingCoordinatorError.invalidWorkerMessage
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

    private func configuredEnvironment(diarizationToken: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("voxscribe-worker-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true, attributes: nil)
        let matplotlibDir = cacheRoot.appendingPathComponent("matplotlib", isDirectory: true)
        let xdgCacheDir = cacheRoot.appendingPathComponent("xdg-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: matplotlibDir, withIntermediateDirectories: true, attributes: nil)
        try? FileManager.default.createDirectory(at: xdgCacheDir, withIntermediateDirectories: true, attributes: nil)
        env["MPLCONFIGDIR"] = matplotlibDir.path
        env["XDG_CACHE_HOME"] = xdgCacheDir.path
        if let diarizationToken, !diarizationToken.isEmpty {
            env["HF_TOKEN"] = diarizationToken
            env["HUGGINGFACE_HUB_TOKEN"] = diarizationToken
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

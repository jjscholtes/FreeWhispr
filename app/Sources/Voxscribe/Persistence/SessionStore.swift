import Foundation

actor SessionStore {
    enum StoreError: LocalizedError {
        case missingManifest(UUID)
        case missingTranscript(UUID)
        case corruptedData(String)

        var errorDescription: String? {
            switch self {
            case .missingManifest(let id): return "Session manifest not found for \(id.uuidString)"
            case .missingTranscript(let id): return "Transcript not found for \(id.uuidString)"
            case .corruptedData(let detail): return "Corrupted data: \(detail)"
            }
        }
    }

    private let fileManager: FileManager
    let baseURL: URL
    let sessionsURL: URL
    let settingsURL: URL

    init(baseURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let baseURL {
            self.baseURL = baseURL
        } else {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.baseURL = appSupport.appendingPathComponent("com.jesse.voxscribe", isDirectory: true)
        }
        self.sessionsURL = self.baseURL.appendingPathComponent("sessions", isDirectory: true)
        self.settingsURL = self.baseURL.appendingPathComponent("settings.json", isDirectory: false)
        try Self.prepareBaseDirectories(fileManager: fileManager, baseURL: self.baseURL, sessionsURL: self.sessionsURL)
    }

    private static func prepareBaseDirectories(fileManager: FileManager, baseURL: URL, sessionsURL: URL) throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: sessionsURL, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: baseURL.appendingPathComponent("logs", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
    }

    func loadSettings() throws -> AppSettings {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            try saveSettings(.default)
            return .default
        }
        let data = try Data(contentsOf: settingsURL)
        return try AppJSON.decoder().decode(AppSettings.self, from: data)
    }

    func saveSettings(_ settings: AppSettings) throws {
        try atomicWrite(data: try settings.encodedData(), to: settingsURL)
    }

    func sessionDirectory(for sessionId: UUID) -> URL {
        sessionsURL.appendingPathComponent(sessionId.uuidString, isDirectory: true)
    }

    func manifestURL(for sessionId: UUID) -> URL {
        sessionDirectory(for: sessionId).appendingPathComponent("manifest.json")
    }

    func audioFileURL(for sessionId: UUID) -> URL {
        sessionDirectory(for: sessionId).appendingPathComponent("audio/source.wav")
    }

    func audioFileURL(for manifest: SessionManifest) -> URL {
        sessionDirectory(for: manifest.id).appendingPathComponent(manifest.audioFileRelativePath)
    }

    func processingDirectory(for sessionId: UUID) -> URL {
        sessionDirectory(for: sessionId).appendingPathComponent("processing", isDirectory: true)
    }

    func transcriptDirectory(for sessionId: UUID) -> URL {
        sessionDirectory(for: sessionId).appendingPathComponent("transcript", isDirectory: true)
    }

    func transcriptJSONURL(for sessionId: UUID) -> URL {
        transcriptDirectory(for: sessionId).appendingPathComponent("transcript.json")
    }

    func createDraftSession(settings: AppSettings) throws -> SessionManifest {
        var manifest = SessionManifest.newDraft(settings: settings)
        manifest.modelConfig.diarizationEnabled = settings.diarizationEnabledByDefault
        try createSessionStructure(for: manifest.id)
        try saveManifest(manifest)
        return manifest
    }

    func createSessionStructure(for sessionId: UUID) throws {
        let sessionDir = sessionDirectory(for: sessionId)
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: sessionDir.appendingPathComponent("audio", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: sessionDir.appendingPathComponent("processing", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: sessionDir.appendingPathComponent("transcript", isDirectory: true), withIntermediateDirectories: true, attributes: nil)
    }

    func importAudioFile(from sourceURL: URL, into sessionId: UUID) throws -> String {
        let extRaw = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = extRaw.isEmpty ? "wav" : extRaw.lowercased()
        let relativePath = "audio/source.\(ext)"
        let destURL = sessionDirectory(for: sessionId).appendingPathComponent(relativePath)

        try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destURL)
        return relativePath
    }

    func saveManifest(_ manifest: SessionManifest) throws {
        let url = manifestURL(for: manifest.id)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try atomicWrite(data: try manifest.encodedData(), to: url)
    }

    func loadManifest(sessionId: UUID) throws -> SessionManifest {
        let url = manifestURL(for: sessionId)
        guard fileManager.fileExists(atPath: url.path) else { throw StoreError.missingManifest(sessionId) }
        let data = try Data(contentsOf: url)
        return try AppJSON.decoder().decode(SessionManifest.self, from: data)
    }

    func listSessions() throws -> [SessionManifest] {
        guard fileManager.fileExists(atPath: sessionsURL.path) else { return [] }
        let children = try fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil)
        var manifests: [SessionManifest] = []
        for dir in children {
            let manifestFile = dir.appendingPathComponent("manifest.json")
            guard fileManager.fileExists(atPath: manifestFile.path) else { continue }
            do {
                let data = try Data(contentsOf: manifestFile)
                let manifest = try AppJSON.decoder().decode(SessionManifest.self, from: data)
                manifests.append(manifest)
            } catch {
                continue
            }
        }
        return manifests.sorted { $0.updatedAt > $1.updatedAt }
    }

    func updateManifest(sessionId: UUID, _ mutate: (inout SessionManifest) -> Void) throws -> SessionManifest {
        var manifest = try loadManifest(sessionId: sessionId)
        mutate(&manifest)
        manifest.updatedAt = Date()
        try saveManifest(manifest)
        return manifest
    }

    func saveTranscript(_ transcript: TranscriptDocument) throws {
        let url = transcriptJSONURL(for: transcript.sessionId)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(transcript)
        try atomicWrite(data: data, to: url)
    }

    func loadTranscript(sessionId: UUID) throws -> TranscriptDocument {
        let url = transcriptJSONURL(for: sessionId)
        guard fileManager.fileExists(atPath: url.path) else { throw StoreError.missingTranscript(sessionId) }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TranscriptDocument.self, from: data)
    }

    func transcriptExists(sessionId: UUID) -> Bool {
        fileManager.fileExists(atPath: transcriptJSONURL(for: sessionId).path)
    }

    func recoverInterruptedJobs() throws -> [SessionManifest] {
        var recovered: [SessionManifest] = []
        for manifest in try listSessions() where manifest.processingState == .running || manifest.processingState == .queued {
            let updated = try updateManifest(sessionId: manifest.id) {
                $0.processingState = .failed
                $0.processingStage = nil
                $0.processingProgress = nil
                $0.lastError = ProcessingError(code: "PROCESSING_INTERRUPTED", message: "Processing was interrupted when the app closed.", details: nil)
            }
            recovered.append(updated)
        }
        return recovered
    }

    func deleteSession(sessionId: UUID) throws {
        let sessionDir = sessionDirectory(for: sessionId)
        guard fileManager.fileExists(atPath: sessionDir.path) else { return }
        try fileManager.removeItem(at: sessionDir)
    }

    func writeTextFile(_ text: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try atomicWrite(data: Data(text.utf8), to: url)
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: tempURL, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: url)
        }
    }
}

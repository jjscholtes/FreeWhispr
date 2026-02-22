import Foundation
import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    enum SessionShelfFilter: String, CaseIterable, Identifiable {
        case all
        case active
        case ready
        case failed

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .active: return "Active"
            case .ready: return "Ready"
            case .failed: return "Failed"
            }
        }
    }

    enum TranscriptSaveState: Equatable {
        case idle
        case saving
        case saved(Date)
        case failed(String)
    }

    enum SessionShelfSelection: Equatable {
        case smart(SessionShelfFilter)
        case unfiled
        case userFolder(UUID)
    }

    struct ProcessingErrorPresentation: Equatable {
        let message: String
        let technicalDetails: String?
    }

    enum MainStage: Equatable {
        case idle
        case recording(UUID)
        case processing(UUID)
        case transcript(UUID)
    }

    @Published var sessions: [SessionManifest] = []
    @Published var selectedSessionID: UUID?
    @Published var currentTranscript: TranscriptDocument?
    @Published var stage: MainStage = .idle
    @Published var searchQuery = ""
    @Published var sessionShelfSelection: SessionShelfSelection = .smart(.all)
    @Published var transcriptSearchQuery = ""
    @Published var transcriptSpeakerFilter: String = "all"
    @Published var transcriptSaveState: TranscriptSaveState = .idle
    @Published var settings: AppSettings = .default
    @Published var huggingFaceToken = ""
    @Published var setupStatus: WorkerSetupStatus?
    @Published var processingProgress: ProcessingProgressEvent?
    @Published var errorMessage: String?
    @Published var errorTechnicalDetails: String?
    @Published var infoMessage: String?
    @Published var isShowingSettings = false
    @Published var isBusyValidatingSetup = false
    @Published var pendingDeleteSession: SessionManifest?
    @Published var pendingRenameSession: SessionManifest?
    @Published var renameSessionDraftTitle = ""
    @Published var isShowingCreateFolderSheet = false
    @Published var createFolderDraftName = ""
    @Published var isShowingExportSheet = false
    @Published var exportFormatSelection = ExportFormatSelection()
    @Published var exportFilenameStem = ""

    let recordingController = RecordingController()

    private let sessionStore: SessionStore
    private let settingsStore: SettingsStore
    private let keychainStore = KeychainStore()
    private let processingCoordinator = ProcessingCoordinator()
    private let projectRootURL: URL
    private var hasBootstrapped = false
    private var processingTask: Task<Void, Never>?
    private var deferredSpeakerRenamePersistTask: Task<Void, Never>?
    private static let lastExportFolderDefaultsKey = "voxscribe.lastExportFolderPath"

    init() {
        do {
            let store = try SessionStore()
            self.sessionStore = store
            self.settingsStore = SettingsStore(sessionStore: store)
        } catch {
            fatalError("Failed to initialize SessionStore: \(error)")
        }
        self.projectRootURL = ProcessingCoordinator.defaultProjectRoot()
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        do {
            settings = try await settingsStore.load()
            if settings.enableMockPipeline {
                // Migrate older dev-first defaults to real inference by default.
                settings.enableMockPipeline = false
                try await settingsStore.save(settings)
            }
        } catch {
            showError(error.localizedDescription)
        }
        do {
            huggingFaceToken = try await keychainStore.loadHuggingFaceToken() ?? ""
        } catch {
            showError(error.localizedDescription)
        }

        do {
            _ = try await sessionStore.recoverInterruptedJobs()
        } catch {
            showError(error.localizedDescription)
        }

        await reloadSessions()
        if let first = sessions.first {
            await openSession(first.id)
        } else {
            stage = .idle
        }
        await validateSetup()
    }

    func reloadSessions() async {
        do {
            sessions = try await sessionStore.listSessions()
        } catch {
            showError(error.localizedDescription)
        }
    }

    var filteredSessions: [SessionManifest] {
        sessions.filter { manifest in
            guard matchesSessionShelfSelection(manifest, selection: sessionShelfSelection) else { return false }

            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            let lower = query.lowercased()
            return manifest.title.lowercased().contains(lower)
                || manifest.id.uuidString.lowercased().contains(lower)
        }
    }

    func sessionCount(for filter: SessionShelfFilter) -> Int {
        sessions.filter { matchesSessionShelfFilter($0, filter: filter) }.count
    }

    func sessionCount(forFolderId folderId: UUID?) -> Int {
        sessions.filter { $0.folderId == folderId }.count
    }

    var userFolders: [SessionFolder] {
        settings.customFolders.sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                return $0.createdAt < $1.createdAt
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func isSelectedSmartFolder(_ filter: SessionShelfFilter) -> Bool {
        sessionShelfSelection == .smart(filter)
    }

    func isSelectedUserFolder(_ folderId: UUID?) -> Bool {
        switch sessionShelfSelection {
        case .unfiled:
            return folderId == nil
        case .userFolder(let selectedId):
            return selectedId == folderId
        case .smart:
            return false
        }
    }

    func selectSmartFolder(_ filter: SessionShelfFilter) {
        sessionShelfSelection = .smart(filter)
    }

    func selectUnfiledFolder() {
        sessionShelfSelection = .unfiled
    }

    func selectUserFolder(_ folderId: UUID) {
        sessionShelfSelection = .userFolder(folderId)
    }

    var selectedManifest: SessionManifest? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var transcriptSpeakerOptions: [(id: String, label: String)] {
        guard let currentTranscript else { return [] }
        return currentTranscript.speakers.map { ($0.id, $0.effectiveLabel) }
    }

    func folderName(for folderId: UUID?) -> String? {
        guard let folderId else { return nil }
        return settings.customFolders.first(where: { $0.id == folderId })?.name
    }

    var transcriptSaveStatusText: String? {
        switch transcriptSaveState {
        case .idle:
            return nil
        case .saving:
            return "Saving…"
        case .saved(let date):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "Saved \(formatter.string(from: date))"
        case .failed:
            return "Save failed"
        }
    }

    var transcriptSaveStateIsError: Bool {
        if case .failed = transcriptSaveState { return true }
        return false
    }

    var exportFilenamePreview: [String] {
        let stem = sanitizedExportStem(exportFilenameStem)
        var files: [String] = []
        if exportFormatSelection.includeJSON { files.append("\(stem).json") }
        if exportFormatSelection.includeTXT { files.append("\(stem).txt") }
        if exportFormatSelection.includeSRT { files.append("\(stem).srt") }
        return files
    }

    var lastExportFolderDisplayName: String? {
        guard let path = UserDefaults.standard.string(forKey: Self.lastExportFolderDefaultsKey) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }

    var filteredTranscriptSegments: [TranscriptSegment] {
        guard let transcript = currentTranscript else { return [] }
        return transcript.segments.filter { segment in
            let speakerMatches = transcriptSpeakerFilter == "all"
                || (transcriptSpeakerFilter == "unassigned" && segment.speakerId == nil)
                || segment.speakerId == transcriptSpeakerFilter

            let query = transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let textMatches = query.isEmpty || segment.text.localizedCaseInsensitiveContains(query)
            return speakerMatches && textMatches
        }
    }

    func newRecording() {
        processingTask?.cancel()
        errorMessage = nil
        infoMessage = nil

        Task { @MainActor in
            do {
                var manifest = try await sessionStore.createDraftSession(settings: settings)
                let audioURL = await sessionStore.audioFileURL(for: manifest.id)
                try await recordingController.startRecording(to: audioURL)
                manifest = try await mutateManifest(sessionId: manifest.id) {
                    $0.recordingState = .recording
                    $0.processingState = .notStarted
                    $0.processingStage = nil
                    $0.processingProgress = nil
                    $0.lastError = nil
                }
                await reloadSessions()
                selectedSessionID = manifest.id
                currentTranscript = nil
                transcriptSaveState = .idle
                stage = .recording(manifest.id)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func importRecording() {
        if recordingController.isRecording {
            showError("Stop the current recording before importing another file.")
            return
        }

        processingTask?.cancel()
        errorMessage = nil
        errorTechnicalDetails = nil
        infoMessage = nil

        let panel = NSOpenPanel()
        panel.title = "Import Recording"
        panel.message = "Choose an audio recording to transcribe."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["wav", "mp3", "m4a", "aac", "flac", "ogg", "opus", "mp4", "mov", "webm"]

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        Task { @MainActor in
            do {
                var manifest = try await sessionStore.createDraftSession(settings: settings)
                let importedRelativePath = try await sessionStore.importAudioFile(from: sourceURL, into: manifest.id)
                let durationMs = importedAudioDurationMs(for: sourceURL) ?? 0
                let importedTitle = defaultImportedSessionTitle(from: sourceURL)

                manifest = try await mutateManifest(sessionId: manifest.id) {
                    $0.title = importedTitle
                    $0.audioFileRelativePath = importedRelativePath
                    $0.recordingState = .stopped
                    $0.processingState = .queued
                    $0.processingStage = .preparing
                    $0.processingProgress = 0.0
                    $0.durationMs = durationMs
                    $0.lastError = nil
                    $0.modelConfig.asrModel = $0.profile.asrModel
                    $0.modelConfig.diarizationEnabled = settings.diarizationEnabledByDefault
                }

                await reloadSessions()
                selectedSessionID = manifest.id
                currentTranscript = nil
                transcriptSaveState = .idle
                stage = .processing(manifest.id)
                showInfo("Imported \(sourceURL.lastPathComponent)")
                startProcessing(sessionId: manifest.id)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func cancelRecording() {
        recordingController.cancelRecording(deleteFile: true)
        errorMessage = nil
        if let selectedSessionID {
            Task { @MainActor in
                do {
                    _ = try await self.mutateManifest(sessionId: selectedSessionID) {
                        $0.recordingState = .idle
                        $0.processingState = .cancelled
                        $0.lastError = ProcessingError(code: "RECORDING_CANCELLED", message: "Recording cancelled before transcription.", details: nil)
                    }
                    await reloadSessions()
                    stage = .idle
                } catch {
                    self.showError(error.localizedDescription)
                }
            }
        } else {
            stage = .idle
        }
    }

    func stopRecording() {
        guard case let .recording(sessionId) = stage else { return }
        let elapsed = recordingController.stopRecording()
        Task { @MainActor in
            do {
                _ = try await mutateManifest(sessionId: sessionId) {
                    $0.recordingState = .stopped
                    $0.processingState = .queued
                    $0.processingStage = .preparing
                    $0.processingProgress = 0.0
                    $0.durationMs = max($0.durationMs, Int(elapsed * 1000))
                    $0.lastError = nil
                    $0.modelConfig.asrModel = $0.profile.asrModel
                    $0.modelConfig.diarizationEnabled = settings.diarizationEnabledByDefault
                }
                await reloadSessions()
                stage = .processing(sessionId)
                startProcessing(sessionId: sessionId)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func startProcessing(sessionId: UUID) {
        processingTask?.cancel()
        processingProgress = nil
        errorMessage = nil
        errorTechnicalDetails = nil

        processingTask = Task { @MainActor in
            do {
                let manifest = try await sessionStore.loadManifest(sessionId: sessionId)
                let audioURL = await sessionStore.audioFileURL(for: manifest)
                let outputDir = await sessionStore.sessionDirectory(for: sessionId)

                _ = try await mutateManifest(sessionId: sessionId) {
                    $0.processingState = .running
                    $0.processingStage = .preparing
                    $0.processingProgress = 0
                    $0.lastError = nil
                }
                await reloadSessions()

                let output = try await processingCoordinator.runTranscriptionJob(
                    projectRoot: projectRootURL,
                    manifest: manifest,
                    audioPath: audioURL,
                    outputDir: outputDir,
                    settings: settings,
                    diarizationToken: normalizedDiarizationToken,
                    workerScriptPath: settings.workerScriptPath,
                    onProgress: { [weak self] event in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.processingProgress = event
                            do {
                                _ = try await self.mutateManifest(sessionId: sessionId) {
                                    $0.processingState = .running
                                    $0.processingStage = event.stage
                                    $0.processingProgress = event.progress
                                }
                                await self.reloadSessions()
                            } catch {
                                self.showError(error.localizedDescription)
                            }
                        }
                    }
                )

                var transcript = try await sessionStore.loadTranscript(sessionId: sessionId)
                transcript.sourceLanguage = output.detectedLanguage ?? transcript.sourceLanguage
                let sessionDir = await sessionStore.sessionDirectory(for: sessionId)
                let artifacts = try await TranscriptExporter.exportAll(transcript, to: sessionDir, using: sessionStore)

                _ = try await mutateManifest(sessionId: sessionId) {
                    $0.processingState = .completed
                    $0.processingStage = nil
                    $0.processingProgress = 1.0
                    $0.artifactStatus = artifacts
                    $0.lastError = nil
                }
                await reloadSessions()
                selectedSessionID = sessionId
                currentTranscript = transcript
                transcriptSaveState = .saved(Date())
                stage = .transcript(sessionId)
                showInfo("Transcript ready")
            } catch is CancellationError {
                showInfo("Processing cancelled.")
            } catch let error as ProcessingCoordinatorError {
                await markProcessingFailure(sessionId: sessionId, code: error.code, message: error.localizedDescription)
            } catch {
                await markProcessingFailure(sessionId: sessionId, code: "UNKNOWN_PROCESSING_ERROR", message: error.localizedDescription)
            }
        }
    }

    private func markProcessingFailure(sessionId: UUID, code: String, message: String) async {
        let presentation = presentProcessingError(code: code, message: message)
        do {
            let state: ProcessingState = (code == "JOB_CANCELLED") ? .cancelled : .failed
            _ = try await mutateManifest(sessionId: sessionId) {
                $0.processingState = state
                $0.processingStage = nil
                $0.processingProgress = nil
                $0.lastError = ProcessingError(
                    code: code,
                    message: presentation.message,
                    details: presentation.technicalDetails.map { ["technical": $0] }
                )
            }
            await reloadSessions()
        } catch {
            showError(error.localizedDescription)
        }
        if code == "JOB_CANCELLED" {
            showInfo("Processing cancelled.")
        } else {
            // Processing failures are already rendered in the processing panel; avoid duplicate top-banner noise.
            errorMessage = nil
            errorTechnicalDetails = nil
        }
        self.stage = .processing(sessionId)
    }

    func cancelProcessing() {
        Task {
            await processingCoordinator.cancelCurrentJob()
        }
    }

    func retryProcessing() {
        if case let .processing(sessionId) = stage {
            startProcessing(sessionId: sessionId)
        } else if let sessionId = selectedSessionID {
            stage = .processing(sessionId)
            startProcessing(sessionId: sessionId)
        }
    }

    func openSession(_ sessionId: UUID) async {
        selectedSessionID = sessionId
        errorMessage = nil
        errorTechnicalDetails = nil
        do {
            let manifest = try await sessionStore.loadManifest(sessionId: sessionId)
            switch manifest.processingState {
            case .completed:
                currentTranscript = try? await sessionStore.loadTranscript(sessionId: sessionId)
                transcriptSaveState = .idle
                stage = .transcript(sessionId)
            case .running, .queued, .failed, .cancelled:
                currentTranscript = (try? await sessionStore.loadTranscript(sessionId: sessionId))
                transcriptSaveState = .idle
                stage = .processing(sessionId)
            case .notStarted:
                currentTranscript = (try? await sessionStore.loadTranscript(sessionId: sessionId))
                transcriptSaveState = .idle
                stage = .idle
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func saveSettings() {
        let settings = self.settings
        let token = huggingFaceToken
        Task { @MainActor in
            do {
                try await settingsStore.save(settings)
                try await keychainStore.saveHuggingFaceToken(token)
                showInfo("Settings saved")
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func validateSetup() async {
        isBusyValidatingSetup = true
        defer { isBusyValidatingSetup = false }
        do {
            setupStatus = try await processingCoordinator.validateSetup(
                projectRoot: projectRootURL,
                diarizationToken: normalizedDiarizationToken,
                workerScriptPath: settings.workerScriptPath
            )
        } catch {
            showError(error.localizedDescription)
        }
    }

    func updateTranscriptSegment(id: String, text: String) {
        guard var transcript = currentTranscript else { return }
        guard let index = transcript.segments.firstIndex(where: { $0.id == id }) else { return }
        transcript.segments[index].text = text
        transcript.segments[index].source = .userEdited
        transcript.touch()
        currentTranscript = transcript
        persistTranscript(transcript)
    }

    func reassignSegment(id: String, speakerId: String?) {
        guard var transcript = currentTranscript else { return }
        guard let index = transcript.segments.firstIndex(where: { $0.id == id }) else { return }
        transcript.segments[index].speakerId = speakerId
        transcript.segments[index].source = .userEdited
        transcript.touch()
        currentTranscript = transcript
        persistTranscript(transcript)
    }

    func renameSpeaker(speakerId: String, displayName: String) {
        guard var transcript = currentTranscript else { return }
        guard let index = transcript.speakers.firstIndex(where: { $0.id == speakerId }) else { return }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTrimmed = transcript.speakers[index].displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed != currentTrimmed else { return }
        transcript.speakers[index].displayName = trimmed.isEmpty ? nil : trimmed
        transcript.speakers[index].isUserEdited = !trimmed.isEmpty
        transcript.touch()
        currentTranscript = transcript
        scheduleSpeakerRenamePersist(transcript)
    }

    private func persistTranscript(_ transcript: TranscriptDocument) {
        deferredSpeakerRenamePersistTask?.cancel()
        deferredSpeakerRenamePersistTask = nil
        Task { @MainActor in
            await performTranscriptPersist(
                transcript,
                includeArtifacts: true,
                reloadSessionList: true
            )
        }
    }

    private func scheduleSpeakerRenamePersist(_ transcript: TranscriptDocument) {
        deferredSpeakerRenamePersistTask?.cancel()
        deferredSpeakerRenamePersistTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.transcriptSaveState = .saving
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await self.performTranscriptPersist(
                transcript,
                includeArtifacts: false,
                reloadSessionList: false
            )
            self.deferredSpeakerRenamePersistTask = nil
        }
    }

    private func performTranscriptPersist(
        _ transcript: TranscriptDocument,
        includeArtifacts: Bool,
        reloadSessionList: Bool
    ) async {
        transcriptSaveState = .saving
        do {
            try await sessionStore.saveTranscript(transcript)
            if includeArtifacts {
                let sessionDir = await sessionStore.sessionDirectory(for: transcript.sessionId)
                let artifacts = try await TranscriptExporter.exportAll(transcript, to: sessionDir, using: sessionStore)
                _ = try await mutateManifest(sessionId: transcript.sessionId) {
                    $0.artifactStatus = artifacts
                }
            }
            if reloadSessionList {
                await reloadSessions()
            }
            transcriptSaveState = .saved(Date())
        } catch is CancellationError {
            // Ignore canceled deferred saves.
        } catch {
            transcriptSaveState = .failed(error.localizedDescription)
            showError(error.localizedDescription)
        }
    }

    func exportCurrentTranscript() {
        guard currentTranscript != nil else { return }
        if exportFilenameStem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            exportFilenameStem = defaultExportFilenameStem()
        }
        isShowingExportSheet = true
    }

    func confirmExportCurrentTranscript() {
        guard let transcript = currentTranscript else { return }
        Task { @MainActor in
            do {
                guard exportFormatSelection.hasAnySelection else {
                    showError("Select at least one export format.")
                    return
                }
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                panel.prompt = "Export Here"
                panel.message = "Choose a folder for transcript export files."
                if let lastPath = UserDefaults.standard.string(forKey: Self.lastExportFolderDefaultsKey) {
                    panel.directoryURL = URL(fileURLWithPath: lastPath, isDirectory: true)
                }
                guard panel.runModal() == .OK, let selectedFolder = panel.url else {
                    return
                }
                UserDefaults.standard.set(selectedFolder.path, forKey: Self.lastExportFolderDefaultsKey)

                let sessionDir = await sessionStore.sessionDirectory(for: transcript.sessionId)
                let artifacts = try await TranscriptExporter.exportAll(transcript, to: sessionDir, using: sessionStore)
                _ = try await mutateManifest(sessionId: transcript.sessionId) {
                    $0.artifactStatus = artifacts
                }
                let exportFolder = selectedFolder.appendingPathComponent(exportFolderName(for: transcript), isDirectory: true)
                let exportResult = try TranscriptExporter.exportForUser(
                    transcript,
                    to: exportFolder,
                    baseFilename: sanitizedExportStem(exportFilenameStem),
                    selection: exportFormatSelection
                )
                await reloadSessions()
                NSWorkspace.shared.activateFileViewerSelecting([exportResult.directoryURL])
                isShowingExportSheet = false
                showInfo("Exported \(exportResult.exportedURLs.count) file(s) to \(exportResult.directoryURL.lastPathComponent)")
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func cancelExportSheet() {
        isShowingExportSheet = false
    }

    func saveCurrentTranscriptNow() {
        guard let transcript = currentTranscript else { return }
        persistTranscript(transcript)
    }

    func revealSessionInFinder(_ sessionId: UUID) {
        Task { @MainActor in
            let sessionDir = await sessionStore.sessionDirectory(for: sessionId)
            NSWorkspace.shared.activateFileViewerSelecting([sessionDir])
        }
    }

    func promptDeleteSession(_ manifest: SessionManifest) {
        pendingDeleteSession = manifest
    }

    func promptCreateFolder() {
        createFolderDraftName = ""
        isShowingCreateFolderSheet = true
    }

    func dismissCreateFolderPrompt() {
        isShowingCreateFolderSheet = false
        createFolderDraftName = ""
    }

    func confirmCreateFolder() {
        let trimmed = createFolderDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showError("Folder name cannot be empty.")
            return
        }
        if settings.customFolders.contains(where: { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            showError("A folder with this name already exists.")
            return
        }

        let folder = SessionFolder(name: trimmed)
        settings.customFolders.append(folder)
        isShowingCreateFolderSheet = false
        createFolderDraftName = ""
        persistSettingsOnly(successMessage: "Folder created")
        sessionShelfSelection = .userFolder(folder.id)
    }

    func promptRenameSession(_ manifest: SessionManifest) {
        pendingRenameSession = manifest
        renameSessionDraftTitle = manifest.title
    }

    func dismissRenamePrompt() {
        pendingRenameSession = nil
        renameSessionDraftTitle = ""
    }

    func confirmRenamePendingSession() {
        guard let manifest = pendingRenameSession else { return }
        let trimmed = renameSessionDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showError("Session name cannot be empty.")
            return
        }
        if trimmed == manifest.title {
            dismissRenamePrompt()
            return
        }

        pendingRenameSession = nil
        renameSessionDraftTitle = ""
        renameSession(manifest, to: trimmed)
    }

    func dismissDeletePrompt() {
        pendingDeleteSession = nil
    }

    func confirmDeletePendingSession() {
        guard let manifest = pendingDeleteSession else { return }
        pendingDeleteSession = nil
        deleteSession(manifest)
    }

    private func deleteSession(_ manifest: SessionManifest) {
        if manifest.recordingState == .recording || manifest.processingState == .running || manifest.processingState == .queued {
            showError("Cancel recording/processing before deleting this session.")
            return
        }

        Task { @MainActor in
            do {
                try await sessionStore.deleteSession(sessionId: manifest.id)
                if selectedSessionID == manifest.id {
                    selectedSessionID = nil
                    currentTranscript = nil
                    stage = .idle
                }
                await reloadSessions()
                if selectedSessionID == nil, let first = sessions.first {
                    await openSession(first.id)
                }
                showInfo("Deleted session")
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func renameSession(_ manifest: SessionManifest, to newTitle: String) {
        Task { @MainActor in
            do {
                _ = try await mutateManifest(sessionId: manifest.id) {
                    $0.title = newTitle
                }
                await reloadSessions()
                showInfo("Renamed session")
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func moveSession(_ manifest: SessionManifest, toFolderId folderId: UUID?) {
        if manifest.recordingState == .recording || manifest.processingState == .running {
            showError("Stop recording/processing before moving this session.")
            return
        }

        Task { @MainActor in
            do {
                _ = try await mutateManifest(sessionId: manifest.id) {
                    $0.folderId = folderId
                }
                await reloadSessions()
                let destinationLabel = folderName(for: folderId) ?? "Unfiled"
                showInfo("Moved to \(destinationLabel)")
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func clearBanner() {
        errorMessage = nil
        errorTechnicalDetails = nil
        infoMessage = nil
    }

    private func mutateManifest(sessionId: UUID, _ mutate: (inout SessionManifest) -> Void) async throws -> SessionManifest {
        var manifest = try await sessionStore.loadManifest(sessionId: sessionId)
        mutate(&manifest)
        manifest.updatedAt = Date()
        try await sessionStore.saveManifest(manifest)
        return manifest
    }

    private func persistSettingsOnly(successMessage: String? = nil) {
        let currentSettings = settings
        Task { @MainActor in
            do {
                try await settingsStore.save(currentSettings)
                if let successMessage {
                    showInfo(successMessage)
                }
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func matchesSessionShelfFilter(_ manifest: SessionManifest, filter: SessionShelfFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .active:
            return manifest.recordingState == .recording
                || manifest.processingState == .queued
                || manifest.processingState == .running
        case .ready:
            return manifest.processingState == .completed
        case .failed:
            return manifest.processingState == .failed
        }
    }

    private func matchesSessionShelfSelection(_ manifest: SessionManifest, selection: SessionShelfSelection) -> Bool {
        switch selection {
        case .smart(let filter):
            return matchesSessionShelfFilter(manifest, filter: filter)
        case .unfiled:
            return manifest.folderId == nil
        case .userFolder(let folderId):
            return manifest.folderId == folderId
        }
    }

    func formatSessionMeta(_ manifest: SessionManifest) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let dateString = formatter.string(from: manifest.updatedAt)
        let durationString = formatDuration(ms: manifest.durationMs)
        return "\(dateString) • \(durationString)"
    }

    func formatDuration(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func currentSessionStatusLabel(_ manifest: SessionManifest) -> String {
        switch manifest.processingState {
        case .notStarted:
            return manifest.recordingState == .recording ? "REC" : "Draft"
        case .queued:
            return "Queued"
        case .running:
            return manifest.processingStage?.displayLabel ?? "Processing"
        case .completed:
            return "Ready"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    private var normalizedDiarizationToken: String? {
        let trimmed = huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func revealProcessingLogs() {
        guard let sessionId = selectedSessionID else { return }
        Task { @MainActor in
            let dir = await sessionStore.processingDirectory(for: sessionId)
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    private func exportFolderName(for transcript: TranscriptDocument) -> String {
        let title = (selectedManifest?.title ?? "Transcript")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedTitle = sanitizeFilename(title.isEmpty ? "Transcript" : title)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        return "\(sanitizedTitle)-\(timestamp)"
    }

    private func sanitizeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let parts = value.components(separatedBy: invalid)
        let compact = parts.joined(separator: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? "Transcript" : compact
    }

    private func sanitizedExportStem(_ value: String) -> String {
        let stem = sanitizeFilename(value)
        return stem.isEmpty ? "transcript" : stem
    }

    private func defaultImportedSessionTitle(from sourceURL: URL) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            return base
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Imported \(formatter.string(from: Date()))"
    }

    private func importedAudioDurationMs(for sourceURL: URL) -> Int? {
        let asset = AVURLAsset(url: sourceURL)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Int((seconds * 1000).rounded())
    }

    private func defaultExportFilenameStem() -> String {
        sanitizeFilename(selectedManifest?.title ?? "transcript").lowercased()
    }

    private func showError(_ message: String, technicalDetails: String? = nil) {
        infoMessage = nil
        errorMessage = message
        errorTechnicalDetails = technicalDetails
    }

    private func showInfo(_ message: String) {
        errorMessage = nil
        errorTechnicalDetails = nil
        infoMessage = message
    }

    private func presentProcessingError(code: String, message: String) -> ProcessingErrorPresentation {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("Cannot access gated repo"),
           trimmed.contains("pyannote/speaker-diarization-community-1")
        {
            return ProcessingErrorPresentation(
                message: "Your Hugging Face token is valid, but this account has not been granted access to the pyannote speaker diarization model yet.",
                technicalDetails: trimmed
            )
        }

        if code == "DIARIZATION_AUTH_REQUIRED" {
            return ProcessingErrorPresentation(
                message: "A Hugging Face token is required for speaker diarization. Add it in Settings and retry.",
                technicalDetails: trimmed == message ? nil : trimmed
            )
        }

        if code == "MODEL_NOT_INSTALLED" {
            return ProcessingErrorPresentation(
                message: "Whisper transcription backend is not installed in the worker runtime.",
                technicalDetails: trimmed
            )
        }

        if code == "DIARIZATION_MODEL_UNAVAILABLE" {
            return ProcessingErrorPresentation(
                message: "Speaker diarization backend is not installed in the worker runtime.",
                technicalDetails: trimmed
            )
        }

        if trimmed.contains("stdout parse error") {
            return ProcessingErrorPresentation(
                message: "The worker printed unexpected output while processing. Please retry. If it keeps happening, open logs and share them.",
                technicalDetails: trimmed
            )
        }

        if code == "WORKER_LAUNCH_FAILED" {
            return ProcessingErrorPresentation(
                message: "The transcription worker could not start.",
                technicalDetails: trimmed
            )
        }

        return ProcessingErrorPresentation(
            message: trimmed.isEmpty ? "Processing failed." : trimmed,
            technicalDetails: nil
        )
    }
}

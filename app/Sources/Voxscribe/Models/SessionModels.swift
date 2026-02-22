import Foundation

enum RecordingState: String, Codable, CaseIterable, Sendable {
    case idle
    case recording
    case stopped
}

enum ProcessingState: String, Codable, CaseIterable, Sendable {
    case notStarted = "not_started"
    case queued
    case running
    case completed
    case failed
    case cancelled
}

enum ProcessingStage: String, Codable, CaseIterable, Sendable {
    case preparing
    case transcribing
    case diarizing
    case reconciling
    case writingOutput = "writing_output"
    case exporting

    var displayLabel: String {
        switch self {
        case .preparing: return "01 Preparing"
        case .transcribing: return "01 Transcribing"
        case .diarizing: return "02 Speaker Split"
        case .reconciling: return "02 Merging Speakers"
        case .writingOutput, .exporting: return "03 Writing Transcript"
        }
    }
}

enum LanguageMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case nl
    case en

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .nl: return "Dutch"
        case .en: return "English"
        }
    }
}

enum ProcessingProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case fast
    case best

    var id: String { rawValue }

    var asrModel: String {
        switch self {
        case .fast: return "turbo"
        case .best: return "large-v3"
        }
    }

    var label: String {
        switch self {
        case .fast: return "Fast"
        case .best: return "Best"
        }
    }
}

struct ModelConfigSnapshot: Codable, Sendable, Equatable {
    var asrModel: String
    var diarizationEnabled: Bool
}

struct SpeakerCountHint: Codable, Sendable, Equatable {
    var min: Int?
    var max: Int?
}

struct ArtifactStatus: Codable, Sendable, Equatable {
    var hasTranscriptJson: Bool
    var hasTxtExport: Bool
    var hasSrtExport: Bool

    static let empty = ArtifactStatus(hasTranscriptJson: false, hasTxtExport: false, hasSrtExport: false)
}

struct ProcessingError: Codable, Sendable, Equatable {
    var code: String
    var message: String
    var details: [String: String]?
}

struct SessionManifest: Codable, Identifiable, Sendable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int = SessionManifest.schemaVersion
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var recordingState: RecordingState
    var processingState: ProcessingState
    var processingStage: ProcessingStage?
    var processingProgress: Double?
    var durationMs: Int
    var audioFileRelativePath: String
    var languageMode: LanguageMode
    var profile: ProcessingProfile
    var modelConfig: ModelConfigSnapshot
    var speakerCountHint: SpeakerCountHint?
    var artifactStatus: ArtifactStatus
    var lastError: ProcessingError?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        title: String,
        recordingState: RecordingState,
        processingState: ProcessingState,
        processingStage: ProcessingStage? = nil,
        processingProgress: Double? = nil,
        durationMs: Int = 0,
        audioFileRelativePath: String = "audio/source.wav",
        languageMode: LanguageMode,
        profile: ProcessingProfile,
        modelConfig: ModelConfigSnapshot,
        speakerCountHint: SpeakerCountHint? = nil,
        artifactStatus: ArtifactStatus = .empty,
        lastError: ProcessingError? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.recordingState = recordingState
        self.processingState = processingState
        self.processingStage = processingStage
        self.processingProgress = processingProgress
        self.durationMs = durationMs
        self.audioFileRelativePath = audioFileRelativePath
        self.languageMode = languageMode
        self.profile = profile
        self.modelConfig = modelConfig
        self.speakerCountHint = speakerCountHint
        self.artifactStatus = artifactStatus
        self.lastError = lastError
    }

    static func newDraft(settings: AppSettings) -> SessionManifest {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return SessionManifest(
            title: "Session \(formatter.string(from: now))",
            recordingState: .idle,
            processingState: .notStarted,
            durationMs: 0,
            languageMode: settings.defaultLanguageMode,
            profile: settings.defaultProfile,
            modelConfig: ModelConfigSnapshot(asrModel: settings.defaultProfile.asrModel, diarizationEnabled: true)
        )
    }
}

struct AppSettings: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int = AppSettings.schemaVersion
    var defaultLanguageMode: LanguageMode
    var defaultProfile: ProcessingProfile
    var workerScriptPath: String?
    var enableMockPipeline: Bool
    var diarizationEnabledByDefault: Bool

    static let `default` = AppSettings(
        defaultLanguageMode: .auto,
        defaultProfile: .fast,
        workerScriptPath: nil,
        enableMockPipeline: false,
        diarizationEnabledByDefault: true
    )
}

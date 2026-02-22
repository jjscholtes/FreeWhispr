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

enum ASRBackend: String, Codable, CaseIterable, Sendable, Identifiable {
    case whisperCpp = "whisper.cpp"
    case fasterWhisper = "faster-whisper"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fasterWhisper: return "faster-whisper"
        case .whisperCpp: return "whisper.cpp"
        }
    }
}

struct ModelConfigSnapshot: Codable, Sendable, Equatable {
    var asrBackend: ASRBackend
    var asrModel: String
    var diarizationEnabled: Bool

    init(asrBackend: ASRBackend = .whisperCpp, asrModel: String, diarizationEnabled: Bool) {
        self.asrBackend = asrBackend
        self.asrModel = asrModel
        self.diarizationEnabled = diarizationEnabled
    }

    enum CodingKeys: String, CodingKey {
        case asrBackend
        case asrModel
        case diarizationEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        asrBackend = try container.decodeIfPresent(ASRBackend.self, forKey: .asrBackend) ?? .whisperCpp
        asrModel = try container.decode(String.self, forKey: .asrModel)
        diarizationEnabled = try container.decode(Bool.self, forKey: .diarizationEnabled)
    }
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

struct SessionFolder: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

struct SessionManifest: Codable, Identifiable, Sendable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int = SessionManifest.schemaVersion
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var folderId: UUID?
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
        folderId: UUID? = nil,
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
        self.folderId = folderId
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
            modelConfig: ModelConfigSnapshot(asrBackend: settings.defaultASRBackend, asrModel: settings.defaultProfile.asrModel, diarizationEnabled: true)
        )
    }
}

struct AppSettings: Codable, Sendable, Equatable {
    static let schemaVersion = 5

    var schemaVersion: Int = AppSettings.schemaVersion
    var defaultLanguageMode: LanguageMode
    var defaultProfile: ProcessingProfile
    var defaultASRBackend: ASRBackend
    var workerScriptPath: String?
    var enableMockPipeline: Bool
    var diarizationEnabledByDefault: Bool
    var customFolders: [SessionFolder]

    init(
        schemaVersion: Int = AppSettings.schemaVersion,
        defaultLanguageMode: LanguageMode,
        defaultProfile: ProcessingProfile,
        defaultASRBackend: ASRBackend,
        workerScriptPath: String?,
        enableMockPipeline: Bool,
        diarizationEnabledByDefault: Bool,
        customFolders: [SessionFolder] = []
    ) {
        self.schemaVersion = schemaVersion
        self.defaultLanguageMode = defaultLanguageMode
        self.defaultProfile = defaultProfile
        self.defaultASRBackend = defaultASRBackend
        self.workerScriptPath = workerScriptPath
        self.enableMockPipeline = enableMockPipeline
        self.diarizationEnabledByDefault = diarizationEnabledByDefault
        self.customFolders = customFolders
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case defaultLanguageMode
        case defaultProfile
        case defaultASRBackend
        case workerScriptPath
        case enableMockPipeline
        case diarizationEnabledByDefault
        case customFolders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        defaultLanguageMode = try container.decode(LanguageMode.self, forKey: .defaultLanguageMode)
        defaultProfile = try container.decode(ProcessingProfile.self, forKey: .defaultProfile)
        defaultASRBackend = try container.decodeIfPresent(ASRBackend.self, forKey: .defaultASRBackend) ?? .whisperCpp
        workerScriptPath = try container.decodeIfPresent(String.self, forKey: .workerScriptPath)
        enableMockPipeline = try container.decodeIfPresent(Bool.self, forKey: .enableMockPipeline) ?? false
        diarizationEnabledByDefault = try container.decodeIfPresent(Bool.self, forKey: .diarizationEnabledByDefault) ?? true
        customFolders = try container.decodeIfPresent([SessionFolder].self, forKey: .customFolders) ?? []
    }

    static let `default` = AppSettings(
        defaultLanguageMode: .auto,
        defaultProfile: .fast,
        defaultASRBackend: .whisperCpp,
        workerScriptPath: nil,
        enableMockPipeline: false,
        diarizationEnabledByDefault: true,
        customFolders: []
    )
}

import Foundation

struct BackendInfo: Codable, Sendable, Equatable {
    var name: String
    var version: String?
    var model: String?
    var metadata: [String: String]?
}

struct Speaker: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var defaultLabel: String
    var displayName: String?
    var colorHex: String
    var isUserEdited: Bool

    var effectiveLabel: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil) ?? defaultLabel
    }
}

struct WordToken: Codable, Sendable, Equatable, Identifiable {
    var startMs: Int
    var endMs: Int
    var text: String
    var probability: Double?
    var speakerId: String?

    var id: String { "\(startMs)-\(endMs)-\(text)" }
}

struct TranscriptSegment: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var startMs: Int
    var endMs: Int
    var speakerId: String?
    var text: String
    var confidence: Double?
    var speakerConfidence: Double?
    var source: SegmentSource
    var words: [WordToken]?
}

enum SegmentSource: String, Codable, Sendable {
    case machine
    case userEdited = "user_edited"
}

struct TranscriptStats: Codable, Sendable, Equatable {
    var segmentCount: Int?
    var speakerCount: Int?
    var wordCount: Int?
    var durationMs: Int?
}

struct TranscriptDocument: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var sessionId: UUID
    var createdAt: Int64
    var updatedAt: Int64
    var sourceLanguage: String?
    var transcriptionBackend: BackendInfo?
    var diarizationBackend: BackendInfo?
    var speakers: [Speaker]
    var segments: [TranscriptSegment]
    var stats: TranscriptStats

    mutating func touch() {
        updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
    }

    func speakerLabel(for speakerId: String?) -> String {
        guard let speakerId else { return "Unassigned" }
        return speakers.first(where: { $0.id == speakerId })?.effectiveLabel ?? "Unassigned"
    }

    static func empty(sessionId: UUID) -> TranscriptDocument {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return TranscriptDocument(
            schemaVersion: 1,
            sessionId: sessionId,
            createdAt: now,
            updatedAt: now,
            sourceLanguage: nil,
            transcriptionBackend: nil,
            diarizationBackend: nil,
            speakers: [],
            segments: [],
            stats: TranscriptStats(segmentCount: 0, speakerCount: 0, wordCount: 0, durationMs: 0)
        )
    }
}

extension TranscriptDocument {
    var durationMs: Int {
        stats.durationMs ?? (segments.map(\.endMs).max() ?? 0)
    }

    var computedSpeakerCount: Int {
        max(stats.speakerCount ?? 0, speakers.count)
    }
}

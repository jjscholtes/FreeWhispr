import Foundation
@testable import Voxscribe

#if canImport(XCTest)
import XCTest

final class SessionStoreTests: XCTestCase {
    private func makeStore() throws -> SessionStore {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxscribeTests-\(UUID().uuidString)", isDirectory: true)
        return try SessionStore(baseURL: base)
    }

    func testCreateDraftSessionPersistsManifest() async throws {
        let store = try makeStore()
        let manifest = try await store.createDraftSession(settings: .default)
        let loaded = try await store.loadManifest(sessionId: manifest.id)

        XCTAssertEqual(loaded.id, manifest.id)
        XCTAssertEqual(loaded.processingState, .notStarted)
        XCTAssertEqual(loaded.profile, .fast)
        XCTAssertEqual(loaded.modelConfig.asrModel, "turbo")
    }

    func testTranscriptExportWritesTXTAndSRT() async throws {
        let store = try makeStore()
        let sessionId = UUID()
        try await store.createSessionStructure(for: sessionId)

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let transcript = TranscriptDocument(
            schemaVersion: 1,
            sessionId: sessionId,
            createdAt: now,
            updatedAt: now,
            sourceLanguage: "en",
            transcriptionBackend: BackendInfo(name: "mock", version: nil, model: "turbo", metadata: nil),
            diarizationBackend: BackendInfo(name: "mock", version: nil, model: "community-1", metadata: nil),
            speakers: [
                Speaker(id: "spk_1", defaultLabel: "Speaker 1", displayName: "Host", colorHex: "#111111", isUserEdited: true),
            ],
            segments: [
                TranscriptSegment(
                    id: "seg_1",
                    startMs: 2000,
                    endMs: 5100,
                    speakerId: "spk_1",
                    text: "Hello there",
                    confidence: 0.9,
                    speakerConfidence: 1.0,
                    source: .machine,
                    words: nil
                ),
            ],
            stats: TranscriptStats(segmentCount: 1, speakerCount: 1, wordCount: 2, durationMs: 5100)
        )

        let sessionDir = await store.sessionDirectory(for: sessionId)
        let artifacts = try await TranscriptExporter.exportAll(transcript, to: sessionDir, using: store)

        XCTAssertTrue(artifacts.hasTranscriptJson)
        XCTAssertTrue(artifacts.hasTxtExport)
        XCTAssertTrue(artifacts.hasSrtExport)

        let txtURL = sessionDir.appendingPathComponent("transcript/transcript.txt")
        let srtURL = sessionDir.appendingPathComponent("transcript/transcript.srt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: txtURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: srtURL.path))

        let txt = try String(contentsOf: txtURL)
        XCTAssertTrue(txt.contains("Host: Hello there"))
    }
}

#else
// Some constrained environments (including mismatched CLT/Xcode setups) fail to expose XCTest to SwiftPM.
// Keep the test target compilable so `swift test` can still be used as an environment check via scripts/swift_test.sh.
struct XCTestUnavailableEnvironmentTests {
    func placeholder() {}
}
#endif

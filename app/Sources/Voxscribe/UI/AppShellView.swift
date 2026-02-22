import AppKit
import SwiftUI

struct AppShellView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            SessionShelfView(viewModel: viewModel)
                .frame(width: 300)
                .background(Color.white)

            Rectangle()
                .fill(DS.ColorToken.borderSoft)
                .frame(width: 1)

            WorkStageContainerView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.ColorToken.bgApp)
        }
        .background(DS.ColorToken.bgApp)
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsView(viewModel: viewModel)
                .frame(width: 620, height: 640)
        }
        .sheet(isPresented: $viewModel.isShowingExportSheet) {
            ExportSheetView(viewModel: viewModel)
                .frame(width: 520, height: 420)
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.pendingRenameSession != nil },
                set: { isPresented in
                    if !isPresented { viewModel.dismissRenamePrompt() }
                }
            )
        ) {
            RenameSessionSheetView(viewModel: viewModel)
                .frame(width: 460, height: 210)
        }
        .confirmationDialog(
            "Delete recording?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteSession != nil },
                set: { isPresented in
                    if !isPresented { viewModel.dismissDeletePrompt() }
                }
            ),
            titleVisibility: .visible,
            presenting: viewModel.pendingDeleteSession
        ) { manifest in
            Button("Delete '\(manifest.title)'", role: .destructive) {
                viewModel.confirmDeletePendingSession()
            }
            Button("Cancel", role: .cancel) {
                viewModel.dismissDeletePrompt()
            }
        } message: { manifest in
            Text("This permanently removes the recording, transcript, and exports for this session.")
        }
    }
}

private struct SessionShelfView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search sessions", text: $viewModel.searchQuery)
                    .textFieldStyle(.roundedBorder)

                Button(action: viewModel.newRecording) {
                    HStack {
                        Image(systemName: "record.circle")
                        Text("New Recording")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)
                .keyboardShortcut("r", modifiers: [.command])

                Button(action: { viewModel.isShowingSettings = true }) {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("Settings")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(",", modifiers: [.command])

                VStack(alignment: .leading, spacing: 6) {
                    CapsLabel(text: "Folders")
                    VStack(spacing: 6) {
                        ForEach(AppViewModel.SessionShelfFilter.allCases) { filter in
                            SessionFolderRow(
                                title: filter.label,
                                count: viewModel.sessionCount(for: filter),
                                selected: viewModel.sessionShelfFilter == filter,
                                action: { viewModel.sessionShelfFilter = filter }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.filteredSessions) { manifest in
                        SessionShelfRowItem(
                            viewModel: viewModel,
                            manifest: manifest
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct SessionFolderRow: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "folder.fill" : "folder")
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? DS.ColorToken.fgPrimary : DS.ColorToken.fgSecondary)
            }
            .foregroundStyle(selected ? DS.ColorToken.fgPrimary : DS.ColorToken.fgSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? DS.ColorToken.bgPanel : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .stroke(selected ? DS.ColorToken.borderStrong : DS.ColorToken.borderSoft.opacity(0.6), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
        .buttonStyle(.plain)
    }
}

private struct SessionShelfRowItem: View {
    @ObservedObject var viewModel: AppViewModel
    let manifest: SessionManifest
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                Task { await viewModel.openSession(manifest.id) }
            } label: {
                SessionRowView(
                    manifest: manifest,
                    metadata: viewModel.formatSessionMeta(manifest),
                    selected: viewModel.selectedSessionID == manifest.id
                )
            }
            .buttonStyle(.plain)

            if isHovered || viewModel.selectedSessionID == manifest.id {
                Menu {
                    Button("Open") {
                        Task { await viewModel.openSession(manifest.id) }
                    }
                    Button("Rename…") {
                        viewModel.promptRenameSession(manifest)
                    }
                    Button("Reveal in Finder") {
                        viewModel.revealSessionInFinder(manifest.id)
                    }
                    Divider()
                    Button("Delete Recording", role: .destructive) {
                        viewModel.promptDeleteSession(manifest)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .padding(8)
                        .background(Color.white.opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .onHover { hovered in
            isHovered = hovered
        }
        .contextMenu {
            Button("Open") {
                Task { await viewModel.openSession(manifest.id) }
            }
            Button("Rename…") {
                viewModel.promptRenameSession(manifest)
            }
            Button("Reveal in Finder") {
                viewModel.revealSessionInFinder(manifest.id)
            }
            Divider()
            Button("Delete Recording", role: .destructive) {
                viewModel.promptDeleteSession(manifest)
            }
        }
    }
}

private struct WorkStageContainerView: View {
    @ObservedObject var viewModel: AppViewModel

    private var suppressErrorBanner: Bool {
        guard case .processing = viewModel.stage else { return false }
        return viewModel.selectedManifest?.lastError != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = viewModel.errorMessage, !suppressErrorBanner {
                BannerView(
                    text: error,
                    isError: true,
                    technicalDetails: viewModel.errorTechnicalDetails,
                    onDismiss: viewModel.clearBanner
                )
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            } else if let info = viewModel.infoMessage {
                BannerView(text: info, isError: false, onDismiss: viewModel.clearBanner)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            } else {
                Spacer().frame(height: 8)
            }

            switch viewModel.stage {
            case .idle:
                IdleStageView(viewModel: viewModel)
            case .recording:
                RecordingStageView(viewModel: viewModel)
            case .processing:
                ProcessingStageView(viewModel: viewModel)
            case .transcript:
                TranscriptStageView(viewModel: viewModel)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StageTopBar: View {
    let leftTitle: String
    let rightButtonTitle: String?
    let onRightTap: (() -> Void)?

    var body: some View {
        HStack {
            CapsLabel(text: leftTitle)
            Spacer()
            if let rightButtonTitle, let onRightTap {
                Button(rightButtonTitle, action: onRightTap)
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }
        }
        .padding(.horizontal, 32)
        .frame(height: 56)
    }
}

private struct IdleStageView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showOptions = false

    var body: some View {
        VStack(spacing: 0) {
            StageTopBar(leftTitle: "Sessions", rightButtonTitle: "Settings") {
                viewModel.isShowingSettings = true
            }

            Spacer()

            VStack(alignment: .leading, spacing: 20) {
                Text("Ready to record")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(DS.ColorToken.fgPrimary)

                Text("Audio stays on this Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.ColorToken.fgSecondary)

                Button(action: viewModel.newRecording) {
                    Text("Start Recording")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)

                Button(showOptions ? "Hide options" : "More options") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showOptions.toggle()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.ColorToken.fgSecondary)

                if showOptions {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            CapsLabel(text: "Language")
                            Picker("Language", selection: $viewModel.settings.defaultLanguageMode) {
                                ForEach(LanguageMode.allCases) { lang in
                                    Text(lang.label).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        HStack {
                            CapsLabel(text: "Mode")
                            Picker("Mode", selection: $viewModel.settings.defaultProfile) {
                                ForEach(ProcessingProfile.allCases) { profile in
                                    Text(profile.label).tag(profile)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        Toggle("Enable diarization", isOn: $viewModel.settings.diarizationEnabledByDefault)
                            .toggleStyle(.checkbox)
                        Button("Save defaults") { viewModel.saveSettings() }
                            .buttonStyle(.bordered)
                    }
                }

                IndexRailView(mode: .idleTicks, height: 8)
                    .frame(height: 8)

                VStack(alignment: .leading, spacing: 4) {
                    CapsLabel(text: "Tip")
                    Text("Allow microphone access when prompted. New recordings appear in the session shelf on the left.")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(32)
            .frame(maxWidth: 720, minHeight: 360, alignment: .leading)
            .background(DS.ColorToken.bgPanel)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
            .padding(.horizontal, 32)

            Spacer()
        }
    }
}

private struct RecordingStageView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var recordingController: RecordingController

    init(viewModel: AppViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._recordingController = ObservedObject(wrappedValue: viewModel.recordingController)
    }

    private var manifest: SessionManifest? { viewModel.selectedManifest }

    var body: some View {
        VStack(spacing: 0) {
            StageTopBar(leftTitle: manifest?.title ?? "Recording", rightButtonTitle: "Cancel") {
                viewModel.cancelRecording()
            }

            Spacer()

            VStack(alignment: .center, spacing: 18) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.black)
                        .frame(width: 7, height: 7)
                    CapsLabel(text: "REC")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(formatElapsed(recordingController.elapsed))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.ColorToken.fgPrimary)

                IndexRailView(mode: .live(recordingController.meterLevels), height: 12)
                    .frame(height: 12)

                Button(action: viewModel.stopRecording) {
                    Text("Stop Recording")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 170)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)

                if let manifest {
                    HStack(spacing: 16) {
                        Text("MIC: MacBook Microphone")
                        Text("LANG: \(manifest.languageMode.rawValue.uppercased())")
                        Text("MODE: \(manifest.profile.rawValue.uppercased())")
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                }
            }
            .padding(32)
            .frame(maxWidth: 760)
            .background(DS.ColorToken.bgPanel)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}

private struct ProcessingStageView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showTechnicalDetails = false
    private var manifest: SessionManifest? { viewModel.selectedManifest }

    var body: some View {
        VStack(spacing: 0) {
            StageTopBar(leftTitle: manifest?.title ?? "Processing", rightButtonTitle: "Open Transcript") {
                if let id = viewModel.selectedSessionID {
                    Task { await viewModel.openSession(id) }
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                Text("Processing recording")
                    .font(.system(size: 24, weight: .semibold))
                Text("This can take a few minutes depending on recording length and quality mode.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.ColorToken.fgSecondary)

                IndexRailView(mode: .progress(viewModel.processingProgress?.progress ?? manifest?.processingProgress ?? 0.05), height: 10)
                    .frame(height: 10)

                if let message = viewModel.processingProgress?.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                } else if currentStage == .preparing {
                    Text("Starting worker…")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    StageRow(number: "01", title: "Transcribing", active: currentStage == .transcribing, stateText: stageText(for: .transcribing))
                    StageRow(number: "02", title: "Speaker Split", active: currentStage == .diarizing || currentStage == .reconciling, stateText: stageText(for: .diarizing))
                    StageRow(number: "03", title: "Writing Transcript", active: currentStage == .writingOutput || currentStage == .exporting, stateText: stageText(for: .writingOutput))
                }

                if let lastError = manifest?.lastError {
                    VStack(alignment: .leading, spacing: 8) {
                        CapsLabel(text: "Failed")
                        Text(lastError.message)
                            .font(.system(size: 13))
                        if let technical = lastError.details?["technical"], !technical.isEmpty {
                            DisclosureGroup(isExpanded: $showTechnicalDetails) {
                                ScrollView {
                                    Text(technical)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(DS.ColorToken.fgSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 120)
                            } label: {
                                Text("Technical details")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(DS.ColorToken.fgSecondary)
                            }
                        }
                        HStack {
                            Button("Retry") { viewModel.retryProcessing() }
                                .buttonStyle(.borderedProminent)
                                .tint(.black)
                            if lastError.code == "DIARIZATION_AUTH_REQUIRED"
                                || lastError.code == "MODEL_NOT_INSTALLED"
                                || lastError.message.localizedCaseInsensitiveContains("hugging face")
                                || lastError.message.localizedCaseInsensitiveContains("pyannote")
                            {
                                Button("Open Settings") { viewModel.isShowingSettings = true }
                                    .buttonStyle(.bordered)
                            }
                            Button("Reveal Logs") { viewModel.revealProcessingLogs() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(12)
                    .background(DS.ColorToken.bgPanelAlt)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                }

                HStack(spacing: 12) {
                    Button("Cancel processing") { viewModel.cancelProcessing() }
                        .buttonStyle(.bordered)
                    Button("Retry") { viewModel.retryProcessing() }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .background(DS.ColorToken.bgPanel)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    private var currentStage: ProcessingStage? {
        viewModel.processingProgress?.stage ?? manifest?.processingStage
    }

    private func stageText(for stage: ProcessingStage) -> String {
        if let current = currentStage {
            if current == stage {
                let percent = Int((viewModel.processingProgress?.progress ?? manifest?.processingProgress ?? 0) * 100)
                return "\(max(0, min(100, percent)))%"
            }
            let order: [ProcessingStage] = [.preparing, .transcribing, .diarizing, .reconciling, .writingOutput, .exporting]
            let currentIndex = order.firstIndex(of: current) ?? 0
            let stageIndex: Int
            switch stage {
            case .transcribing: stageIndex = 1
            case .diarizing: stageIndex = 2
            case .writingOutput: stageIndex = 4
            default: stageIndex = 0
            }
            return stageIndex < currentIndex ? "done" : "waiting"
        }

        switch manifest?.processingState {
        case .completed: return "done"
        case .failed: return "failed"
        case .queued, .running: return "waiting"
        default: return "waiting"
        }
    }
}

private struct StageRow: View {
    let number: String
    let title: String
    let active: Bool
    let stateText: String

    var body: some View {
        HStack {
            Text("[\(number)]")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(stateText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(active ? DS.ColorToken.fgPrimary : DS.ColorToken.fgSecondary)
        .padding(.vertical, 4)
    }
}

private struct TranscriptStageView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            topBar
            if let transcript = viewModel.currentTranscript {
                transcriptHeader(transcript)
                speakerRenameStrip(transcript)
                segmentList(transcript)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcript not available yet")
                        .font(.system(size: 20, weight: .semibold))
                    Button("Retry Processing") { viewModel.retryProcessing() }
                        .buttonStyle(.borderedProminent)
                        .tint(.black)
                }
                .padding(32)
                .background(DS.ColorToken.bgPanel)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(viewModel.selectedManifest?.title ?? "Transcript")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DS.ColorToken.fgPrimary)

            if let manifest = viewModel.selectedManifest {
                CapsLabel(text: manifest.processingState == .completed ? "Ready" : viewModel.currentSessionStatusLabel(manifest))
                Text(viewModel.formatDuration(ms: manifest.durationMs))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                Text(manifest.languageMode == .auto ? "AUTO" : manifest.languageMode.rawValue.uppercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }
            if let saveText = viewModel.transcriptSaveStatusText {
                Text(saveText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(viewModel.transcriptSaveStateIsError ? DS.ColorToken.fgPrimary : DS.ColorToken.fgSecondary)
            }
            Spacer()
            if let manifest = viewModel.selectedManifest {
                Button("Rename…") { viewModel.promptRenameSession(manifest) }
                    .buttonStyle(.bordered)
            }
            Button("Save") { viewModel.saveCurrentTranscriptNow() }
                .buttonStyle(.bordered)
                .keyboardShortcut("s", modifiers: [.command])
            Button("Export…") { viewModel.exportCurrentTranscript() }
                .buttonStyle(.borderedProminent)
                .tint(.black)
                .keyboardShortcut("e", modifiers: [.command])
            if let sessionId = viewModel.selectedSessionID {
                Button("Reveal Files") { viewModel.revealSessionInFinder(sessionId) }
                    .buttonStyle(.bordered)
            }
            Button("Settings") { viewModel.isShowingSettings = true }
                .buttonStyle(.bordered)
                .keyboardShortcut(",", modifiers: [.command])
            if let manifest = viewModel.selectedManifest {
                Button("Delete") { viewModel.promptDeleteSession(manifest) }
                    .buttonStyle(.bordered)
            }
        }
        .frame(height: 56)
    }

    private func transcriptHeader(_ transcript: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            IndexRailView(mode: .speakerSummary(Array(transcript.segments.prefix(40))), height: 10)
                .frame(height: 10)

            HStack(spacing: 12) {
                TextField("Search transcript", text: $viewModel.transcriptSearchQuery)
                    .textFieldStyle(.roundedBorder)

                Picker("Filter", selection: $viewModel.transcriptSpeakerFilter) {
                    Text("All").tag("all")
                    Text("Unassigned").tag("unassigned")
                    ForEach(transcript.speakers) { speaker in
                        Text(speaker.effectiveLabel).tag(speaker.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
            }
        }
        .padding(16)
        .background(DS.ColorToken.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    private func speakerRenameStrip(_ transcript: TranscriptDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel(text: "Speakers")
            FlowLayout(spacing: 8) {
                ForEach(Array(transcript.speakers.enumerated()), id: \.element.id) { index, speaker in
                    SpeakerRenameChip(
                        speaker: speaker,
                        index: index + 1,
                        onRename: { newName in
                            viewModel.renameSpeaker(speakerId: speaker.id, displayName: newName)
                        }
                    )
                }
            }
        }
        .padding(16)
        .background(DS.ColorToken.bgPanelAlt)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    private func segmentList(_ transcript: TranscriptDocument) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(viewModel.filteredTranscriptSegments) { segment in
                    TranscriptSegmentRowView(
                        segment: segment,
                        transcript: transcript,
                        speakerOptions: viewModel.transcriptSpeakerOptions,
                        onCommitText: { newText in
                            viewModel.updateTranscriptSegment(id: segment.id, text: newText)
                        },
                        onAssignSpeaker: { speakerId in
                            viewModel.reassignSegment(id: segment.id, speakerId: speakerId)
                        }
                    )
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct SpeakerRenameChip: View {
    let speaker: Speaker
    let index: Int
    let onRename: (String) -> Void
    @State private var name: String = ""
    @State private var lastCommittedName: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            SpeakerBadgeView(label: "S\(index)", styleIndex: index)
            TextField("Speaker \(index)", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 140)
                .focused($isFocused)
                .onSubmit {
                    commitIfNeeded()
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        commitIfNeeded()
                    }
                }
            Button("Save") { commitIfNeeded() }
                .buttonStyle(.plain)
                .foregroundStyle(DS.ColorToken.fgSecondary)
        }
        .padding(8)
        .background(Color.white)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
        .onAppear { syncFromSpeaker() }
        .onChange(of: speaker.displayName) { _, _ in
            if !isFocused {
                syncFromSpeaker()
            }
        }
        .onChange(of: speaker.id) { _, _ in
            syncFromSpeaker()
        }
    }

    private func commitIfNeeded() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = lastCommittedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != current else {
            name = trimmed
            return
        }
        onRename(trimmed)
        name = trimmed
        lastCommittedName = trimmed
    }

    private func syncFromSpeaker() {
        let current = speaker.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        name = current
        lastCommittedName = current
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        // Simple fallback for v1: horizontal scroll keeps implementation small.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing, content: content)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.system(size: 24, weight: .semibold))
                Spacer()
                Button("Done") { viewModel.isShowingSettings = false }
                    .buttonStyle(.borderedProminent)
                    .tint(.black)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    settingsCard(title: "Recording Defaults", subtitle: "Applied when you start a new recording.") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Language", selection: $viewModel.settings.defaultLanguageMode) {
                                ForEach(LanguageMode.allCases) { lang in
                                    Text(lang.label).tag(lang)
                                }
                            }
                            Picker("Profile", selection: $viewModel.settings.defaultProfile) {
                                ForEach(ProcessingProfile.allCases) { profile in
                                    Text(profile.label).tag(profile)
                                }
                            }
                            Toggle("Enable speaker diarization by default", isOn: $viewModel.settings.diarizationEnabledByDefault)
                                .toggleStyle(.checkbox)
                        }
                    }

                    settingsCard(title: "Model Access", subtitle: "Required for pyannote speaker diarization (stored in macOS Keychain).") {
                        VStack(alignment: .leading, spacing: 10) {
                            SecureField("Hugging Face token (pyannote)", text: $viewModel.huggingFaceToken)
                                .textFieldStyle(.roundedBorder)
                            Text("If diarization fails with a 401 error, your token is valid but your Hugging Face account still needs access to the gated pyannote model.")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.ColorToken.fgSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Open pyannote model page") {
                                    if let url = URL(string: "https://huggingface.co/pyannote/speaker-diarization-community-1") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered)
                                Button("Clear token") {
                                    viewModel.huggingFaceToken = ""
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    settingsCard(title: "Machine Setup", subtitle: "Checks the bundled/local worker runtime and model backends.") {
                        VStack(alignment: .leading, spacing: 10) {
                            if viewModel.isBusyValidatingSetup {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Validating worker setup…")
                                        .font(.system(size: 12))
                                        .foregroundStyle(DS.ColorToken.fgSecondary)
                                }
                            } else if let status = viewModel.setupStatus {
                                HStack(spacing: 8) {
                                    Capsule()
                                        .fill(status.status == "ready" ? Color.black : Color.clear)
                                        .overlay(Capsule().stroke(DS.ColorToken.fgPrimary, lineWidth: 1))
                                        .frame(width: 54, height: 20)
                                    Text(status.status == "ready" ? "Ready" : "Needs setup")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                setupLine("Whisper backend", status.fasterWhisperAvailable ? "Available" : "Missing")
                                setupLine("Diarization backend", status.pyannoteAvailable ? "Available" : "Missing")
                                setupLine("HF token", status.diarizationTokenPresent ? "Present" : "Missing")
                                if !status.missingDependencies.isEmpty {
                                    Text("Missing: \(status.missingDependencies.joined(separator: ", "))")
                                        .font(.system(size: 12))
                                        .foregroundStyle(DS.ColorToken.fgSecondary)
                                }
                            } else {
                                Text("Run setup validation to check worker runtime and model dependencies.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DS.ColorToken.fgSecondary)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                CapsLabel(text: "Advanced")
                                TextField(
                                    "Worker script path override (optional)",
                                    text: Binding(
                                        get: { viewModel.settings.workerScriptPath ?? "" },
                                        set: { viewModel.settings.workerScriptPath = $0.isEmpty ? nil : $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Validate setup") {
                            Task { await viewModel.validateSetup() }
                        }
                        .buttonStyle(.bordered)
                        Button("Save settings") { viewModel.saveSettings() }
                            .buttonStyle(.borderedProminent)
                            .tint(.black)
                    }
                    .padding(.top, 4)
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .background(DS.ColorToken.bgApp)
    }

    @ViewBuilder
    private func settingsCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.ColorToken.fgPrimary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(DS.ColorToken.fgSecondary)
            content()
        }
        .padding(14)
        .background(DS.ColorToken.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    private func setupLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DS.ColorToken.fgSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.ColorToken.fgPrimary)
        }
    }
}

private struct ExportSheetView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Export Transcript")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("Close") { viewModel.cancelExportSheet() }
                    .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Filename")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                TextField("transcript", text: $viewModel.exportFilenameStem)
                    .textFieldStyle(.roundedBorder)
                Text("Files will be exported into a new folder inside the location you choose.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }
            .padding(14)
            .background(DS.ColorToken.bgPanel)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))

            VStack(alignment: .leading, spacing: 10) {
                Text("Formats")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                Toggle("JSON (full transcript data)", isOn: $viewModel.exportFormatSelection.includeJSON)
                    .toggleStyle(.checkbox)
                Toggle("TXT (readable transcript)", isOn: $viewModel.exportFormatSelection.includeTXT)
                    .toggleStyle(.checkbox)
                Toggle("SRT (subtitles)", isOn: $viewModel.exportFormatSelection.includeSRT)
                    .toggleStyle(.checkbox)
            }
            .padding(14)
            .background(DS.ColorToken.bgPanel)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Filename Preview")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                    Spacer()
                    if let lastFolder = viewModel.lastExportFolderDisplayName {
                        Text("Last folder: \(lastFolder)")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                    }
                }
                if viewModel.exportFilenamePreview.isEmpty {
                    Text("Select at least one format.")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                } else {
                    ForEach(viewModel.exportFilenamePreview, id: \.self) { filename in
                        Text(filename)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DS.ColorToken.fgPrimary)
                    }
                }
            }
            .padding(14)
            .background(DS.ColorToken.bgPanelAlt)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") { viewModel.cancelExportSheet() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Choose Folder & Export") { viewModel.confirmExportCurrentTranscript() }
                    .buttonStyle(.borderedProminent)
                    .tint(.black)
                    .disabled(!viewModel.exportFormatSelection.hasAnySelection)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .background(DS.ColorToken.bgApp)
    }
}

private struct RenameSessionSheetView: View {
    @ObservedObject var viewModel: AppViewModel
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Rename Session")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("Close") { viewModel.dismissRenamePrompt() }
                    .buttonStyle(.bordered)
            }

            if let manifest = viewModel.pendingRenameSession {
                Text("Update the session name shown in the session list and transcript header.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.ColorToken.fgSecondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Session name")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                    TextField("Session name", text: $viewModel.renameSessionDraftTitle)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFieldFocused)
                        .onSubmit { viewModel.confirmRenamePendingSession() }
                    Text("Session ID: \(manifest.id.uuidString)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(14)
                .background(DS.ColorToken.bgPanel)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") { viewModel.dismissRenamePrompt() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save Name") { viewModel.confirmRenamePendingSession() }
                    .buttonStyle(.borderedProminent)
                    .tint(.black)
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.renameSessionDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .background(DS.ColorToken.bgApp)
        .onAppear {
            DispatchQueue.main.async {
                isNameFieldFocused = true
            }
        }
    }
}

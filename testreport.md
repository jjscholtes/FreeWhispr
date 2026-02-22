# Test Report

## Scope
- **What was tested**: Automated Swift/Python test runners, plus targeted UI/UX regression triage for speaker naming and button visibility in the macOS SwiftUI app (`Kopie`) using code inspection and user-reported screenshots.
- **What was not tested**: Full interactive manual UI run-through on this machine (no UI automation harness in repo), dark mode/accessibility contrast modes, drag/drop/import edge cases, and end-to-end recording/processing in this pass.

## Results by Task
### UI/UX Regression Triage (speaker editing + button visibility)
- **Verification Notes Followed**: N/A (ad hoc regression triage request)
- **Automated Tests Added/Updated**: None (UI regressions; no existing UI test harness)
- **Commands Run**:
  - `./scripts/swift_test.sh`
  - `python3 -m unittest discover -s worker/tests -p 'test_*.py'`
  - `rg` / `nl -ba` inspection of SwiftUI files
- **Outcome**: fail
- **Notes/Risks**:
  - Automated tests pass but do not cover the reported UI/UX regressions.
  - Multiple regressions remain in speaker editing and visual contrast of controls.

## Findings (ordered by severity)
1. **[High] Speaker rename autosave triggers heavy disk/export work on every typing pause, causing UI jitter/focus instability**
   - `SpeakerRenameChip` autosaves after `350ms` while focused (`scheduleAutosave`) and calls `onRename(...)` repeatedly: `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift:947`
   - `renameSpeaker(...)` immediately persists the entire transcript: `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/AppViewModel.swift:581`
   - `persistTranscript(...)` writes transcript, re-exports artifacts (`txt/srt/json`), mutates manifest, and reloads session list on each save: `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/AppViewModel.swift:594`
   - Likely user-visible symptom: speaker name fields feel “weird”, focus/typing feels unreliable, lag while editing.

2. **[High] Speaker rename text field text is not reliably visible while editing (user-reported repro)**
   - The chip uses a plain `TextField` with `.foregroundStyle(...)`, which is not a reliable way to force editable AppKit text color during active editing on macOS: `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift:878`
   - Combined with a light custom background, this can result in low/no visible typed text depending on system appearance/accent settings.

3. **[Medium] Transcript row speaker name is still intentionally truncated, so “full name” will not display in many cases**
   - The row label hard-limits to one line with tail truncation: `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/Components/TranscriptSegmentRowView.swift:31`
   - It is constrained to a fixed `230pt` width menu label frame: `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/Components/TranscriptSegmentRowView.swift:39`
   - User expectation (“I want to see the whole name”) is not met by the current layout.

4. **[Medium] Button visibility is inconsistent because many controls use default `.bordered` styling without explicit monochrome tint/foreground**
   - Sidebar secondary actions (`Import Recording…`, `Settings`) are plain bordered controls with no explicit tint: `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift:89`, `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift:99`
   - Settings panel action buttons (e.g. `Open pyannote model page`, `Clear token`, `Validate setup`) also use `.bordered` without explicit tint: `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift:1017`, `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift:1078`
   - On some macOS accent/appearance configurations these controls can look like nearly white pills with poor contrast.

5. **[Medium] Speaker chip “Save” button remains visually weak in the monochrome system**
   - The chip card is white (`Color.white`) and the `Save` button is default `.bordered`, so contrast relies on system control styling rather than the app’s design tokens: `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift:904`, `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift:909`
   - This matches the user report that button(s) appear white / hard to see.

6. **[Low] Speaker-name editing model is ambiguous (global speaker rename vs per-line label edit)**
   - Top “Speakers” chips rename the speaker entity globally (`renameSpeaker`) while transcript rows only reassign speaker IDs via a `Menu`: `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift:866`, `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/Components/TranscriptSegmentRowView.swift:22`
   - UX wording and row affordances do not clearly communicate that distinction, increasing confusion when users try to “change a name on a specific line.”

## Summary
- **Overall status**: fail (UI/UX regressions reproduced/validated; automated tests do not cover them)
- **Key risks**:
  - Editing interactions remain unreliable/laggy due to autosave path doing heavy work on every pause.
  - Contrast/visibility issues will continue to cause usability failures across different macOS themes/accent settings.
  - Speaker-label UX still conflicts with user expectations (full names + local vs global edits).

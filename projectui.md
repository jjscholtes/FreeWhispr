# UI Design Specification (Coder Handoff)

## 1. Intent

- **Primary user moment**: User is about to start a conversation recording, or wants to quickly reopen a past transcript.
- **Primary tasks**:
- Start recording in one click
- Stop recording and understand processing state
- Reopen and review/edit/export a transcript
- **Desired feel**: Precise, calm, monochrome, tool-like (inspired by Weber Workshops' restraint and hierarchy), never dashboard-busy.

## 2. Direction (Weber-Inspired, Monochrome)

- **Visual language**:
- High contrast, mostly black/white/grays
- Strong typography hierarchy
- Sparse chrome, generous whitespace
- Small uppercase labels for metadata
- Numbered process stages (`01`, `02`, `03`)
- **No visual clutter**:
- No colorful cards/grids
- No multicolor speaker chips
- No heavy shadows
- **Signature element**:
- `Index Rail`: a thin horizontal strip with time ticks and black/white blocks (session progress, processing progress, or speaker turn summary depending on state)

## 3. Design System (Monochrome Tokens)

### Color Tokens

- `bg.app`: `#FFFFFF`
- `bg.panel`: `#F6F6F4`
- `bg.panelAlt`: `#FAFAF8`
- `fg.primary`: `#111111`
- `fg.secondary`: `#616161`
- `fg.tertiary`: `#8C8C8C`
- `border.soft`: `#DDDDDD`
- `border.strong`: `#BDBDBD`
- `state.active`: `#111111`
- `state.inactive`: `#EAEAEA`
- `state.error`: `#111111` (use icon/label, not color)
- `state.recording`: `#111111` (strict monochrome default)
- `focus.ring`: `#111111`

### Optional Practical Exception (if you allow one accent later)

- `state.recording.red`: `#D92D20`

### Typography

- `Display XL`: SF Pro Display 32/36, semibold (main headings / idle CTA title)
- `Display L`: SF Pro Display 24/28, semibold (section titles)
- `Body`: SF Pro Text 14/20, regular (transcript text)
- `Body Strong`: SF Pro Text 14/20, semibold (speaker labels, row titles)
- `Label Caps`: SF Pro Text 11/14, semibold, uppercase tracking +8% (metadata/status labels)
- `Meta Mono`: SF Mono 12/16, medium (timestamps, timer, durations)
- `Timer Mono`: SF Mono 28/32, semibold (recording timer)

### Spacing Scale

- Base unit: `4`
- Scale: `4, 8, 12, 16, 20, 24, 32, 40`

### Radius

- `r.sm = 8`
- `r.md = 12`
- `r.lg = 18`
- `r.pill = 999`

### Depth Strategy

- Borders only + surface tone changes
- No drop shadows in MVP

### Motion

- Hover/focus: `120ms`
- Panel/state transitions: `180ms`
- Reduce motion support required

## 4. App Structure and Navigation

### Navigation Model (Simple)

- **Left Shelf**: session list + search + new recording button
- **Main Stage**: one active state view (`Idle`, `Recording`, `Processing`, `Transcript`)
- **Settings**: separate sheet/window (not always visible)

### Why

- Keeps retrieval always available (session shelf)
- Keeps the current task clear (main stage only shows one thing)
- Avoids split-panel overload

## 5. Layout Spec (Desktop)

### Window Assumptions

- Target default window: `1280 x 820`
- Minimum supported layout: `1100 x 720`
- Content padding: `24` outer padding

### App Shell Regions

- `Left Shelf` width: `300`
- `Shelf/Main divider`: `1px` soft border
- `Main Stage` width: remaining space
- `Main Stage` inner padding: `32`

### Shell Wireframe (All States)

```text
+---------------------------------------------------------------+
| Left Shelf (300)          | Main Stage                        |
|---------------------------|-----------------------------------|
| Search                    | Top Bar                           |
| New Recording             | (state title / actions)           |
| Session list rows         |                                   |
| ...                       | State-specific content            |
|                           |                                   |
+---------------------------------------------------------------+
```

## 6. Screen-by-Screen Wireframe Specs

### A. Idle / Empty State (Primary First-Run Screen)

#### Goal

- Make `Start Recording` the most obvious action in the app.

#### Main Stage Layout

- Top bar height: `56`
- Content centered within max width `720`
- Vertical stack with `24` gap

#### Blocks

- `Top Bar`
- Left: app state label (`SESSIONS`)
- Right: small button `Settings`
- `Hero Record Panel` (centerpiece)
- Approx size: `min(720w, 100%) x 360h`
- Background: `bg.panel`
- Border: `border.soft`
- Radius: `r.lg`
- `Hero Title`: “Ready to record”
- `Hero Subtitle`: short privacy line (“Audio stays on this Mac.”)
- `Primary Button`: `Start Recording`
- `Secondary Text Button`: `More options` (collapsed settings: language/profile)
- `Index Rail` (idle mode)
- Thin 6px rail with neutral ticks, no segments yet
- `Quick Tips` (compact, optional)
- 2 short lines max: mic permission + where sessions appear

#### Wireframe

```text
Main Stage

[Top Bar...............................................[Settings]]

          +--------------------------------------------------+
          | READY TO RECORD                                  |
          | Audio stays on this Mac.                         |
          |                                                  |
          | [ Start Recording ]                              |
          | [ More options ]                                 |
          |                                                  |
          | ====|====|====|====|====  (Index Rail idle)      |
          +--------------------------------------------------+
```

#### Component States

- `Start Recording` hover: invert fill (black bg / white text)
- `More options` expands inline (no modal)
- If mic permission missing: primary button remains visible but triggers permission explanation sheet first

### B. Recording State

#### Goal

- User should feel confident recording is active and know how to stop.

#### Main Stage Layout

- Centered recording panel max width `760`
- Strong vertical hierarchy

#### Blocks

- `Top Bar`
- Left: session title (auto-generated, editable later)
- Right: `Cancel` text button (with confirm)
- `Recording Panel`
- Timer (`Timer Mono`) centered
- Recording indicator: blinking dot + `REC` label (monochrome)
- Level meter (horizontal bars)
- `Index Rail` live mode (scrolling ticks / elapsed progress)
- Primary stop button `Stop Recording`
- `Metadata Row`
- Mic source
- Language mode (`AUTO`, `DUTCH`, `ENGLISH`)
- Profile (`FAST`, `BEST`)

#### Wireframe

```text
[Session 2026-02-22 14:32...................................[Cancel]]

          +--------------------------------------------------+
          | REC  •                                           |
          |                                                  |
          |                    00:12:48                      |
          |                                                  |
          | [|||||||||| ||||||| |||| ||||||||||]            |
          |                                                  |
          | ==|===|====|====|====|===|==  (Index Rail live)  |
          |                                                  |
          | [ Stop Recording ]                               |
          +--------------------------------------------------+

          MIC: MacBook Pro Microphone   LANG: AUTO   MODE: FAST
```

#### Component States

- `Stop Recording` is the only filled primary button
- Meter bars animate with audio level
- `Cancel` asks confirmation to discard current recording

### C. Processing State (After Stop)

#### Goal

- Explain what is happening in plain language and reduce “is it stuck?” anxiety.

#### Main Stage Layout

- Max width `760`
- Panel with stage list + active progress

#### Blocks

- `Top Bar`
- Left: session title
- Right: `Open Transcript` disabled until complete
- `Processing Panel`
- Status title: “Processing recording”
- Subtext: “This can take a few minutes depending on length and quality mode.”
- `Index Rail` progress mode (fills across)
- `Stage List`
- `01 Transcribing`
- `02 Speaker Split`
- `03 Writing Transcript`
- Active stage row includes spinner/progress text
- `Secondary Actions`
- `Cancel processing`
- `Retry` (only after failure)
- `Show details` disclosure (logs/errors)

#### Wireframe (Running)

```text
[Interview with Tim................................[Open Transcript disabled]]

          +--------------------------------------------------+
          | PROCESSING RECORDING                             |
          | This can take a few minutes.                     |
          |                                                  |
          | ========|===========|======                      |
          |                                                  |
          | [01] TRANSCRIBING           62%                  |
          | [02] SPEAKER SPLIT          waiting              |
          | [03] WRITING TRANSCRIPT     waiting              |
          |                                                  |
          | [Cancel processing] [Show details]               |
          +--------------------------------------------------+
```

#### Failure Variant

- Replace active stage row text with `FAILED`
- Add compact bordered error panel under stage list with:
- one-line cause
- primary recovery (`Retry`)
- secondary (`Open Settings` if setup issue)
- tertiary disclosure (`Details`)

### D. Transcript Ready State (Primary Review Screen)

#### Goal

- Make transcript easy to read, edit, and navigate while keeping the UI calm.

#### Main Stage Layout

- Top bar + transcript header + segment list
- Transcript content max width `920`
- Segment rows full available width

#### Blocks

- `Top Bar`
- Left: session title
- Center/left metadata labels (`READY`, duration, language, speakers)
- Right: `Export` button
- `Transcript Header Panel`
- `Index Rail` speaker summary mode (segments in patterns for S1/S2/S3)
- Search field (local to transcript)
- Optional filter: `All / S1 / S2 / Unassigned`
- `Transcript Segment List`
- Rows with timestamp / speaker badge / editable text
- `Footer Summary` (optional compact)
- word count / updated time

#### Wireframe

```text
[Interview with Tim]  READY  42 MIN  DUTCH/EN  2 SPEAKERS .......... [Export]

+---------------------------------------------------------------------+
| ==##====----###===--==---===   (Index Rail speaker summary)         |
| [Search transcript..............]   [All v]                          |
+---------------------------------------------------------------------+

00:00:02   [S1]   Thanks for joining, can you explain how...
00:00:06   [S2]   Yes, the main issue was the deployment...
00:00:11   [S1]   Right, and when did that start?
...
```

#### Segment Row Spec

- Row min height: `44` (expands with wrapped text)
- Gap between columns: `12`
- Timestamp column width: `84`
- Speaker column width: `64`
- Text column: fill remaining
- Row padding: `10 vertical`, `8 horizontal`
- Hover state: `bg.panelAlt`
- Active edit state: 1px strong border around text area only

#### Speaker Badge Styles (Monochrome)

- `S1`: black fill, white text
- `S2`: white fill, black border
- `S3`: white fill, double border
- `S4`: white fill, dashed border
- All badges same size for layout stability

#### Edit Interactions

- Clicking text enters inline edit mode
- `Cmd+Enter` commits segment edit
- `Esc` cancels segment edit (reverts current row edits)
- Clicking speaker badge opens small menu:
- Reassign to `S1`, `S2`, `S3`, `S4`, `Unassigned`
- `Rename speakers...` opens rename popover

### E. Session Shelf (Left Side) Spec

#### Goal

- Make past transcriptions easy to find without adding complex navigation.

#### Layout

- Shelf padding: `16`
- Internal vertical gap: `12`

#### Blocks

- `Search Sessions` field (sticky top)
- `New Recording` button
- `Session Rows` scroll list

#### Session Row Layout

- Min row height: `72`
- Padding: `12`
- Border radius: `r.md`
- Border: `1px border.soft`
- Row content:
- Title (1 line, truncate)
- Meta line (date • duration)
- Status line OR mini `Index Rail`

#### Status Patterns (Monochrome)

- `Recording`: `REC` label + blinking dot
- `Processing`: progress rail + stage code (`01`, `02`, `03`)
- `Ready`: mini speaker-summary rail
- `Failed`: `FAILED` label + warning icon (monochrome)

#### Selection / Interaction

- Hover: panel tone lift
- Selected: stronger border + slightly darker panel
- Keyboard up/down supported
- `Enter` opens selected session

### F. Settings Sheet (Simple, Not Overwhelming)

#### Goal

- Keep recording flow clean while still exposing necessary setup.

#### Presentation

- Modal sheet or separate window
- Width `620`, height auto (max `700`)

#### Sections (collapsible)

- `Default Recording`
- Input device
- Default language (`Auto`, `Dutch`, `English`)
- `Processing Mode`
- Default profile (`Fast`, `Best`)
- `Diarization Setup`
- Worker status (`Ready` / `Needs setup`)
- Hugging Face token status (masked)
- `Validate setup` button
- `Storage`
- App data location
- Open sessions folder

#### Rules

- No settings are required to start first recording (except mic permission)
- Setup blockers surface here and in processing error panels

## 7. Component Specifications (Reusable SwiftUI Targets)

### `IndexRailView`

- Height variants:
- `small = 6`
- `medium = 10`
- `large = 14`
- Modes:
- `idleTicks`
- `progress(fraction, stageMarkers)`
- `live(elapsed, pulse)`
- `speakerSummary(segments)`
- Rendering:
- Base line + ticks + optional blocks/patterns
- Use monochrome patterns instead of colors for speakers

### `SessionRowView`

- Props:
- title
- metadata string
- status model
- selected state
- onOpen

### `RecordingPanelView`

- Props:
- elapsed time
- isRecording
- audioLevel samples
- profile/language labels
- onStop
- onCancel

### `ProcessingPanelView`

- Props:
- current stage
- stage statuses
- progress fraction
- error (optional)
- actions (cancel/retry/show details)

### `TranscriptSegmentRowView`

- Props:
- timestamp
- speaker style
- text
- editing state
- confidence/needsReview flag (optional icon only)
- callbacks for edit/reassign

### `SpeakerBadgeView`

- Variants:
- `s1Filled`
- `s2Outline`
- `s3Double`
- `s4Dashed`
- `unassigned`

## 8. Interaction and State Matrix (Coder-Oriented)

### App Main State Enum

- `idle`
- `recording(sessionId)`
- `processing(sessionId, stage, progress)`
- `transcript(sessionId)`

### Session Status Enum (Shelf Rows)

- `recording`
- `queued`
- `processing(stage, progress)`
- `ready`
- `failed(errorCode)`

### Primary Actions by State

- `idle` -> `Start Recording`
- `recording` -> `Stop Recording`
- `processing` -> `Cancel processing` / `Retry` (if failed)
- `transcript` -> `Export`, `Edit`, `Reassign speaker`

## 9. Accessibility and Usability Requirements

- Full keyboard navigation in session shelf and transcript rows
- Focus ring visible in monochrome (2px black outline or inset)
- Speaker differentiation cannot rely on color (already monochrome-safe)
- Dynamic type support where practical, but preserve transcript row alignment
- Reduce-motion mode disables blinking/pulsing and uses static indicators
- Minimum contrast ratio AA for all text and controls

## 10. Implementation Notes for `$coder`

### Suggested SwiftUI View Tree

- `AppShellView`
- `SessionShelfView`
- `WorkStageContainerView`
- `IdleStageView`
- `RecordingStageView`
- `ProcessingStageView`
- `TranscriptStageView`
- `SettingsView`

### Suggested Supporting Views

- `IndexRailView`
- `SessionRowView`
- `SectionLabelCapsView`
- `SpeakerBadgeView`
- `TranscriptSegmentRowView`
- `EmptyStatePanelView`
- `ErrorInlinePanelView`

### Constants to Centralize

- Shelf width, paddings, row heights, radii, border widths
- Typography styles
- Monochrome token values
- Stage labels and stage numbering

### Implementation Order (UI)

- Build app shell + session shelf skeleton
- Build idle + recording stage
- Build processing stage
- Build transcript stage with fake data
- Add edit/reassign interactions
- Connect to real session/processing state

## 11. Non-Goals for UI v1

- Fancy waveform editor
- Real-time scrolling live transcript
- Drag-and-drop timeline editing
- Multi-window power-user transcript compare mode
- Theme chooser / dark mode variant before the monochrome baseline is solid

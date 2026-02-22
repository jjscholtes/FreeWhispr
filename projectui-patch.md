# UI Patch Spec (Coder-Ready) - Kopie

## Intent
- **User**: iemand die net een opname heeft gemaakt/geimporteerd en snel een transcript wil ordenen en corrigeren.
- **Task**: sessie hernoemen, verplaatsen naar map, speakers benoemen en speakerlabels betrouwbaar terugzien in transcriptregels.
- **Feel**: precies, rustig, voorspelbaar. Controls moeten duidelijk klikbaar zijn en edits moeten direct zichtbaar zijn waar de gebruiker ze verwacht.

## Direction
De app heeft al een sterke basis (monochroom + recorder/transcript focus), maar de UX breekt op **semantiek van controls**:
- `Rename…` klopt technisch (dialoog volgt), maar de dialoog voelt te krap.
- `Move` is nu een zwakke/losse menu-label i.p.v. een duidelijke actieknop.
- Speakernamen worden bovenin beheerd, maar transcriptregels tonen nog te sterk `S1/S2` i.p.v. de naam die de gebruiker net invoerde.
- Sommige velden/knoppen leunen nog op native styling, waardoor contrast en placeholder-visibility inconsistent zijn.

### Domain -> layout decisions
- `Session actions` worden behandeld als een duidelijke toolstrip (Rename, Move, Export, Save).
- `Speaker identity` wordt opgesplitst in:
  - **Global speaker names** (bovenin)
  - **Segment speaker assignment** (per regel)
- `Transcript rows` tonen **naam eerst**, systeemcode (`S1`) tweede.

### Defaults to replace
- Kale `Menu("Move")` -> button-like menu control (`Move to Folder ▾`)
- Krappe rename modal -> ruimere dialoog met minder primaire ruis
- Placeholder-only fields -> gelabelde velden met consistente componentstyle

## System

### Tokens (component semantics to add)
Voeg componenttokens toe in `DS` zodat controls niet terugvallen op OS-defaults:
- `controlBg`
- `controlBgPressed`
- `controlBorder`
- `fieldBg`
- `fieldBorder`
- `fieldText`
- `fieldPlaceholder`
- `chipBg`
- `chipBorder`

Gebruik bestaande primitives als basis (`bgPanel`, `bgPanelAlt`, `fgPrimary`, `borderSoft`, `borderStrong`) in:
- `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/DesignSystem.swift`

### Typography hierarchy adjustments
- In transcript speaker cell:
  - `Primary`: speaker display name (semibold 12-13)
  - `Secondary`: `S1`, `S2` (mono 10-11)
- `Speaker` micro-label kan blijven, maar mag niet de primary label verdringen.

### State rules (important)
- `Unassigned`: toon expliciet `Unassigned` (nooit lege speakerweergave)
- `Missing reference`: toon `Unknown speaker` + subtiele warning-style (debug fallback)
- `Edited row`: houd `Edited` badge, maar speaker cell moet zichtbaar blijven na reassign

## Structure

### Transcript top bar
Doel: minder ambiguity, betere groepering

#### Current issues
- `Move` menu voelt los van label (`borderlessButton`)
- teveel acties in één visuele rij zonder grouping
- `Rename…` is oké qua ellipsis-semantiek, maar label kan specifieker

#### Patch
- Houd `Rename…` (ellipses zijn correct omdat dialoog opent), maar **rename naar** `Rename Session…`
- Vervang `Menu("Move")` met custom menu label als knop:
  - tekst: `Move to Folder`
  - chevron
  - zelfde visuele style als secondary buttons
- Groepeer acties:
  - `Session`: Rename Session…, Move to Folder
  - `Transcript`: Save, Export…
  - `Utility`: Reveal Files
  - `Danger`: Delete (aparte spacing)

Target:
- `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift` (top bar around current `TranscriptStageView.topBar`)

### Rename session dialog
#### Current issue
- Popup is te krap, vooral met session ID in primary content

#### Patch
- Sheet size aanpassen:
  - van `460x210` naar `560x280` (minimum)
- `Session ID` verplaatsen naar disclosure `Show Details` of secundaire footerregel
- Primary content focussen op 1 taak: naam wijzigen

Target:
- `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift:42`
- `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift:1307`

## Components

### 1. `SessionActionMenuButton` (new)
**Purpose**: duidelijke menu-action button (voor `Move to Folder`)

#### Spec
- Visual: zelfde container als `dsSecondaryButton`
- Label inhoud:
  - icon optional (`folder`)
  - text `Move to Folder`
  - `chevron.down`
- Hit area = volledige button container
- Geen `.menuStyle(.borderlessButton)` op kale text

#### Behavior
- Open menu direct onder/aan de button (visueel gekoppeld)
- Menu items:
  - `Unfiled`
  - divider
  - custom folders
  - divider
  - `New Folder…`

#### Implementation notes
- Maak een reusable `Menu` label helper in `AppShellView` of aparte component file.
- Als `Menu` styling botst met `ButtonStyle`, style het label intern met `HStack + background + overlay` i.p.v. `buttonStyle(...)`.

### 2. `RenameSessionSheetView` (resize + content cleanup)
#### Spec
- Title: `Rename Session`
- Subtitle: `Update how this session appears in the sidebar and transcript header.`
- Input card with:
  - label `Session name`
  - text field
- Secondary details:
  - collapsible `Details` with Session ID (not always visible)
- Actions:
  - `Cancel` (secondary)
  - `Rename Session` (prominent)

#### Sizing
- `width: 560`, `height: 280`
- If details disclosure is expanded, allow vertical growth or scroll

### 3. `SearchFieldView` (new reusable component)
**Problem solved**: inconsistent placeholders / low discoverability

#### Use in
- session shelf search
- transcript search

#### Spec
- Small caps label above field (`Search`)
- Field row:
  - magnifying glass icon
  - text field
- Always visible border + white field background
- Explicit readable text + placeholder in light monochrome mode
- Optional clear button (`xmark.circle.fill`) when text non-empty (P1)

Targets:
- `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift` (session shelf + transcript header)

### 4. `SpeakerRenameChip` (global speaker name)
**Current mental model problem**: user weet niet altijd dat dit globaal is.

#### Patch spec
- Section title: `Global Speaker Names`
- Helper line: `Renaming here updates all rows assigned to this speaker.`
- Chip layout:
  - badge (`S1`)
  - text field (readable, light-mode field styling)
  - trailing state/cta:
    - Either `Apply` button **or** autosave status text (`Saving…` / `Saved`)

#### Recommended behavior (simplify)
- Keep autosave
- Replace `Save` button with subtle status text per chip (`Saved`, `Unsaved`)
- Optional `Apply` button only if autosave disabled

#### Data behavior (must preserve)
- Renaming updates `Speaker.displayName`
- Transcript row labels update immediately
- No heavy export/reload on each keystroke (already partially fixed)

Targets:
- `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift` (`speakerRenameStrip`, `SpeakerRenameChip`)
- `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/AppViewModel.swift` (speaker save pipeline)

### 5. `TranscriptSegmentRowView` speaker cell redesign (highest priority)
This is the main UX fix.

#### Current issues (user-visible)
- `S1/S2` dominate visually over custom names
- changing assignment can produce unclear/blank speaker display state
- control does not clearly look like an editable assignment control

#### Patch spec
- Replace current bare menu label with a **speaker assignment control** container:
  - left: badge (`S1`)
  - middle primary: full speaker name (e.g. `Karel`)
  - middle secondary: `Assigned speaker` or `Speaker S1`
  - right: chevron
- Always show a label even in edge cases:
  - `Unassigned`
  - `Unknown speaker` if `speakerId` not found in transcript speaker array

#### Content priority
- Primary visible label = `effectiveLabel`
- Badge = compact identifier only
- No truncation by default:
  - allow wrapping to 2 lines OR
  - widen column and use `.lineLimit(2)`

#### Menu copy
- `Assign to Unassigned`
- `Assign to Karel`
- `Assign to Scott`

#### Visual state
- Control has border + background (same language as buttons/fields)
- Hover/pressed state subtle surface shift

Target:
- `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/Components/TranscriptSegmentRowView.swift`

### 6. `SpeakerBadgeView` visual rebalance
Goal: badge should support the name, not overpower it.

#### Patch
- Keep badge monospace
- Slightly reduce contrast/weight for non-primary styles
- Ensure width consistency even when `UN`

Target:
- `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/Components/SpeakerBadgeView.swift`

## Validation

### Swap test
- After patch, topbar controls and speaker assignment should feel specific to a transcript editor (not generic macOS menus).

### Squint test
- Transcript row hierarchy should read as:
  - timestamp
  - speaker identity (human-readable)
  - transcript text

### Signature test
Keep `IndexRail`, but extend product identity via:
1. Search field style
2. Speaker chip style
3. Speaker assignment row control
4. Topbar action controls
5. Monochrome field/button system consistency

### Token test
- No raw ad hoc control colors in components.
- Field/button/menu containers route through DS tokens/componenttokens.

## Implementation (coder patch plan)

### Phase P0 (fix user trust)
1. **Transcript speaker row assignment control redesign**
   - `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/Components/TranscriptSegmentRowView.swift`
   - Acceptance:
     - custom speaker names visible in transcript rows
     - reassign never results in empty speaker display
     - control visibly looks interactive

2. **Rename session sheet resize + content cleanup**
   - `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift`
   - Acceptance:
     - no cramped layout at default window scale
     - `Rename Session…` action semantics preserved

3. **Move to Folder menu as button-like control**
   - `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift`
   - Acceptance:
     - menu anchor feels attached to control
     - spacing consistent with neighboring buttons

### Phase P1 (consistency + polish)
4. **Reusable `SearchFieldView` and `LabeledTextFieldView`**
   - `/Users/jessescholtes/Development/voice to text/app/Sources/Voxscribe/UI/AppShellView.swift` or new component files
   - Apply to:
     - session search
     - transcript search
     - rename/create folder fields (where appropriate)

5. **Speaker rename chip polish**
   - Rename section title to `Global Speaker Names`
   - Replace `Save` button with autosave status or `Apply`
   - Consistent readable text/placeholder styling

6. **Topbar action grouping**
   - visually group session actions vs transcript actions
   - move `Delete` slightly away from `Export`

### Phase P2 (subtle fixes / likely future UX bugs)
7. **Empty/missing speaker state audit**
   - verify all rows render fallback text for nil/missing speaker IDs
   - add regression tests for `TranscriptDocument.speakerLabel(...)` + row rendering assumptions

8. **Control affordance audit across app**
   - Ensure no core action uses unstyled `borderless` text-only controls unless intentionally lightweight
   - check settings, export sheet, create folder sheet, processing panel actions

## Acceptance Checklist (manual)
- [ ] `Rename Session…` opens a comfortable modal (not cramped)
- [ ] `Move to Folder` looks like a button, menu opens anchored to it
- [ ] Custom speaker names appear in transcript rows as primary labels
- [ ] Reassigning a row speaker never leaves speaker display blank
- [ ] Sidebar search field is obviously a search field
- [ ] Transcript search field is obviously a search field
- [ ] Global speaker rename strip clearly communicates “updates all rows”
- [ ] Buttons/menus remain readable and clickable in app default theme

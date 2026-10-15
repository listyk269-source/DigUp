---
name: DigUp Graph Workspace
description: Graph, face-investigation, and People workspaces with graphite surfaces, glass file cards, and amber/cyan state cues.
colors:
  graphite: "#202429"
  inspector: "#252b32"
  inspector-overlay: "#252b32ed"
  glass-top: "#454b52"
  glass-bottom: "#2b3036"
  quiet-fill: "#323940cc"
  quiet-solid: "#323940"
  quiet-hover: "#424c57"
  active-fill: "#3a4652"
  control-stroke: "#505962"
  divider: "#414952"
  text: "#eef2f6"
  button-text: "#e1e7ee"
  secondary-text: "#b4bec8"
  node-text: "#f0f2f5"
  node-secondary: "#afb8c1"
  amber: "#f0a048"
  amber-fill: "#483827"
  amber-label: "#d6bd9b"
  action-fill: "#52402d"
  action-text: "#f5d8af"
  cyan: "#77acc5"
  cyan-fill: "#293b47"
  cyan-label: "#a9cadc"
  confirmed: "#83cda2"
  confirmed-fill: "#2c4236"
  confirmed-text: "#b8e5ca"
  rejected: "#d99c99"
  rejected-fill: "#483334"
  rejected-text: "#f0cfcd"
  modality-fill: "#293039"
  media-stage: "#181c21"
  scrollbar-thumb: "#687785"
  scrollbar-hover: "#8999a8"
typography:
  title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "16px"
    fontWeight: 600
  panel-title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "13px"
    fontWeight: 600
  file-name:
    fontFamily: "Segoe UI, sans-serif"
    fontSize: "14px"
    fontWeight: 500
  file-kind:
    fontFamily: "Segoe UI, sans-serif"
    fontSize: "12.5px"
  body:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "12px"
    lineHeight: 1.5
  label:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "12px"
  metadata:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "11px"
rounded:
  control: "8px"
  file-card: "10px"
  minimap: "9px"
  thumbnail: "5px"
  score: "12px"
  chip: "16px"
  face-box: "3px"
spacing:
  compact: "6px"
  control-gap: "7px"
  small: "8px"
  medium: "10px"
  large: "16px"
  pane: "18px"
components:
  button-quiet:
    backgroundColor: "{colors.quiet-fill}"
    textColor: "{colors.button-text}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
  button-quiet-hover:
    backgroundColor: "{colors.quiet-hover}"
  button-active:
    backgroundColor: "{colors.active-fill}"
    textColor: "{colors.button-text}"
    rounded: "{rounded.control}"
  button-similar:
    backgroundColor: "{colors.action-fill}"
    textColor: "{colors.action-text}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
  button-confirm:
    backgroundColor: "{colors.confirmed-fill}"
    textColor: "{colors.confirmed-text}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
  button-reject:
    backgroundColor: "{colors.rejected-fill}"
    textColor: "{colors.rejected-text}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
  modality-chip:
    backgroundColor: "{colors.modality-fill}"
    rounded: "{rounded.chip}"
    padding: "5px 10px"
  graph-omnibar:
    backgroundColor: "{colors.inspector}"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
  inspector-overlay:
    backgroundColor: "{colors.inspector-overlay}"
    width: "360px"
    padding: "14px"
  file-card:
    textColor: "{colors.node-text}"
    typography: "{typography.file-name}"
    rounded: "{rounded.file-card}"
    width: "244px"
    height: "72px"
  file-card-selected:
    backgroundColor: "{colors.amber-fill}"
    textColor: "{colors.node-text}"
    rounded: "{rounded.file-card}"
    width: "244px"
    height: "72px"
  file-card-video:
    backgroundColor: "{colors.cyan-fill}"
    textColor: "{colors.node-text}"
    rounded: "{rounded.file-card}"
    width: "244px"
    height: "72px"
  face-source-stage:
    backgroundColor: "{colors.media-stage}"
    rounded: "{rounded.file-card}"
  face-control:
    backgroundColor: "{colors.quiet-solid}"
    textColor: "{colors.button-text}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
  face-choice:
    backgroundColor: "{colors.glass-bottom}"
    textColor: "{colors.button-text}"
    typography: "{typography.metadata}"
    rounded: "{rounded.control}"
    padding: "5px"
  face-choice-selected:
    backgroundColor: "{colors.amber-fill}"
    textColor: "{colors.action-text}"
    rounded: "{rounded.control}"
  face-result-selected:
    backgroundColor: "{colors.cyan-fill}"
    textColor: "{colors.text}"
    rounded: "{rounded.control}"
    padding: "9px 6px"
  people-field:
    backgroundColor: "{colors.inspector}"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "8px 10px"
  person-directory-item-selected:
    backgroundColor: "{colors.cyan-fill}"
    textColor: "{colors.text}"
    rounded: "{rounded.control}"
    padding: "10px 8px"
  person-mode-active:
    backgroundColor: "{colors.active-fill}"
    textColor: "{colors.button-text}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
  people-action-bar:
    textColor: "{colors.secondary-text}"
    typography: "{typography.label}"
    padding: "10px 18px"
  automatic-face-status:
    backgroundColor: "var(--surface)"
    textColor: "var(--text)"
    typography: "{typography.label}"
    padding: "5px 18px"
    height: "44px"
  people-pending-badge:
    backgroundColor: "var(--selected)"
    textColor: "var(--text)"
    rounded: "{rounded.control}"
    padding: "1px 5px"
  people-undo:
    backgroundColor: "{colors.cyan-fill}"
    textColor: "{colors.button-text}"
    typography: "{typography.label}"
    padding: "9px 18px"
---

# Design System: DigUp Graph Workspace

## Overview

**Creative North Star: "Graphite, Glass, Amber/Cyan"**

This system applies to DigUp's Tauri graph workspace, its face-investigation and People extensions, and their active shell colors. It records the implemented interpretation of the user's pinned dark canvas reference. The desktop launcher, normal search layout, setup flow, and other native surfaces retain their incumbent design; this is a scoped workspace system.

A restrained graphite canvas supports compact translucent horizontal file cards. Amber identifies the selected file and emphasizes its unverified incident links; cyan distinguishes video cards. Green and muted red record the operator's confirmed and rejected link states. Authored outline icons and actual local thumbnails carry file identity. The canvas remains dense enough for exploration while the overlay inspector supplies readable file and match evidence.

Face investigation reuses that graphite material, native type, quiet controls, and warm selection. A large source photograph or sampled video frame carries numbered cyan face boxes; the selected observation and crop adopt amber. Actual face crops, file names, cosine values, and reported video times make candidate review concrete. The indexing strip and persistent candidate-language footer remain part of the working surface.

People extends that working material into a compact label directory, observation list, and media preview. Cyan identifies the current person and inspected observation; separate native checkboxes identify the observations targeted by the bottom action bar. Assigned, Suggestions, Excluded, and Needs review remain explicit text groups. Local label changes expose a wrapping Undo strip, and persistent copy distinguishes the operator's labels from verified identities.

A persistent automatic-face status row extends the existing search shell below its ordinary index strip. It inherits that shell's light/dark colors and the active graphite workspace colors, keeping the checked preference, file/observation progress, and explicit pause readable without replacing the search design. Pending People suggestions use a quiet badge, a toolbar total, and per-label directory counts; they remain suggestions requiring the operator's confirmation.

**Key Characteristics:**
- A world-anchored grid and stable file neighborhoods.
- Glass plates with small rounded corners and restrained state glows.
- Native sans typography, measured filename truncation, and modality/cosine pills.
- Visible search/index context, graph search and filters, a collapsible evidence inspector, and an operable minimap.
- A source-led face workspace with local indexing controls, observation crops, paged candidates, and media evidence.
- A People directory with explicit review groups, independent preview and bulk selection, local label forms, and visible undo.
- Persistent automatic-face preference/progress and synchronized pending-suggestion counts in the existing shell.

Source of truth: `shell/ui/graph.css`, its extension `shell/ui/graph-investigation.css`, SVG construction in `shell/ui/graph.js`, investigation behavior in `shell/ui/graph-tools.js` and `shell/ui/graph-state.js`, markup in `shell/ui/index.html`, and RU/EN strings in `shell/ui/i18n.js`. Corrected native WebView captures of file evidence, match comparison, timeline, context menu, and documents confirm the composition at (1280 × 900 DIP); synthetic fixture content is evidence of rendering, not brand imagery. `docs/graph-investigation.md` records the evidence and capability boundaries.

The face extension is implemented in `shell/ui/faces.css`, `shell/ui/faces.js`, and `shell/ui/face-state.js`, with graph entry points in `shell/ui/graph.js` and `shell/ui/graph-tools.js`. Native captures at `../work/faces-development-h264/review-faces-select.png`, `review-faces-matches.png`, and `review-faces-video.png` establish its source-selection, candidate, and timed-video composition. The later dark-scrollbar treatment is taken from the current stylesheet; those earlier captures do not establish its final packaged appearance.

The People extension is implemented in `shell/ui/people.css`, `shell/ui/people.js`, and `shell/ui/people-state.js`, reusing `shell/ui/faces.css` and candidate integration in `shell/ui/faces.js`, with markup in `shell/ui/index.html` and RU/EN copy in `shell/ui/i18n.js`. Native captures at `../work/people-development-ui-confirm/capture-first-people-assigned.png`, `capture-restart-people-suggestions.png`, and `capture-first-people-rename.png` establish assigned review, suggestions after restart, and the inline rename/undo composition. Synthetic capture content establishes layout and states, not identity evidence.

The automatic-face shell extension is implemented in `shell/ui/faces.css`, `shell/ui/faces.js`, and `shell/ui/people.js`, with markup in `shell/ui/index.html` and RU/EN copy in `shell/ui/i18n.js`; its inherited shell variables and quiet-button base come from `shell/ui/panel.css`. Native captures at `../work/auto-faces-development-ui-confirm/capture-live-auto-waiting.png` and `capture-live-auto-progress.png` (1170 × 840 pixels), plus `capture-live-auto-suggestions.png` and `capture-live-auto-paused.png` (1920 × 1350 pixels), establish waiting, active file progress, synchronized pending counts, and explicit paused composition. Capture sizes are image pixels, not a new window-size rule. These states preserve the existing preview/checkbox distinction, action bar, and local-label disclaimer.

## Colors

Cool graphite neutrals establish the working surface; warm selection and cool video cues explain state without coloring every file.

### Primary
- **Amber:** Selected-card outline, keyboard focus, minimap selection, and selected-file link emphasis. In Faces it marks the selected source observation, numbered box, and crop. The selected fill and label soften the same warm state.
- **Warm Action:** The Find similar action uses a muted warm fill and pale warm text rather than a saturated banner.

### Secondary
- **Cyan:** Video-card outlines and the corresponding cool fill/metadata. Selected video cards adopt the amber selection state. In the face workspace, cyan marks unselected detection boxes and the active candidate row; this scoped use distinguishes the observation being searched from the candidate being inspected. People reuses the cyan fill and border for the current directory label and previewed observation; its checkboxes use the cyan accent, and the Undo strip uses the same cool fill.

The persistent shell row uses the existing shell amber for its native preference checkbox, progress, and focus outline. Its pending badge inherits the shell selected fill; it does not change the workspace meaning of cyan or amber.

### Tertiary
- **Confirmed Green:** Solid confirmed links, their pill borders, and the Confirm link action. This records a local human assessment.
- **Rejected Red:** Rejected links when Show rejected is enabled and the False positive action. Rejected links are hidden by default.

### Neutral
- **Graphite:** Canvas, score-label backplates, and graph-active outer background.
- **Inspector / Inspector Overlay:** The explanatory footer, People name/filter fields, scrollbar tracks, and translucent file/match evidence overlay.
- **Glass Top / Glass Bottom:** The default file plate's vertical translucent gradient.
- **Quiet Fill / Quiet Solid / Quiet Hover / Active Fill:** Compact controls and their interaction states; face and People controls use the opaque quiet surface. Active observation-group buttons use the active fill with a stronger cool border.
- **Control Stroke / Divider:** Functional boundaries between controls, canvas, inspector, and footer.
- **Text / Secondary Text:** General graph text and supporting status information.
- **Node Text / Node Secondary:** File names and file-kind labels.
- **Modality Fill:** Quiet modality chips and link-pill backplates.
- **Media Stage:** The dark backplate behind source media and observation crops.
- **Scrollbar Thumb / Scrollbar Hover:** Visible cool-gray handles over the inspector-colored track in face-source, candidate-list, preview, and People directory/observation panes.

**The State Color Rule.** In the graph, amber follows the selected card, active unverified links, and a requested shortest path; cyan identifies unselected video cards. In Faces, amber follows the selected source observation, while cyan identifies available face boxes and the active candidate row. Confirmed links retain green during ordinary selection; rejected links use muted red only when explicitly shown. Pair review colors with line patterns and inspector text.

**The Separate Selection Rule.** In People and face-result lists, the cyan row highlight chooses a preview. A separate checkbox chooses an observation for label actions. A preview highlight never implies that its checkbox is checked; Assigned and Suggestions remain separate labelled groups.

## Typography

**Body Font:** The inherited native sans stack in the frontmatter.
**Graph Label Font:** Segoe UI with a sans-serif fallback.

**Character:** A compact utility hierarchy serves filenames, metadata, and controls. There is no display type role in this graph surface.

### Hierarchy
- **Title:** Graph heading, with a semibold weight.
- **Panel Title:** Face-workspace subsection headings and the face-index status heading.
- **File Name:** Medium-weight file identity inside the card; fit to a measured text width (166 world units) using a middle ellipsis.
- **File Kind:** Supporting type label below the file name.
- **Body:** Inspector explanation and footer note; the inspector title is semibold at the file-name size.
- **Label:** Buttons, threshold controls, status, neighboring-file actions, and cosine scores.
- **Metadata:** Paths, minimap heading, and zoom readout. Scores and zoom values use tabular numerals.

People uses the title size for the current person's heading, the panel-title size with medium weight (500) for directory names, and the existing label/metadata sizes for forms, row filenames, observation counts, and reported times. Long person names and status/undo text wrap; observation filenames retain single-line ellipsis with full filename context in the preview.

The persistent automatic-face row uses the label size, with tabular status numbers. Its People badge is smaller (10px) with tabular numerals; directory pending counts reuse the metadata size and secondary text beneath the assigned count.

**The Filename Rule.** Preserve the filename's beginning and ending when truncating. Keep full paths available through the card title and inspector instead of shrinking the type.

## Layout

The graph occupies a vertically stacked workspace below the existing search field and index status. A heading/status/omnibar/back row sits above threshold and camera controls, modality filters, layout selection, and concise feedback. A flexible clipped canvas fills the main area; an independently scrolling inspector overlays its right side. The explanatory note stays below the workspace.

The graph window requests up to (1280 × 900 DIP), clamped to the monitor work area. Leaving graph restores the search window's (780 DIP) width. Canvas coordinates are world units: cards are (244 × 72), with hard separation of (320 × 124). Force relaxation and radial anchors arrange new neighbors while existing nodes stay pinned between expansions. Camera movement does not rerun layout.

The canvas grid repeats every (48 world units). Initial camera zoom is (75%); controls support (20–200%). The minimap is (160px) wide and sits (16px) from the lower edge; its right inset becomes (376px) while the inspector is open. The inspector is (360px) wide with (14px) internal padding and a (180px) file preview. It remains that width through the compact toolbar breakpoint (1050px). At widths up to (700px), its width is capped at the canvas width minus (24px), and the minimap is hidden while the overlay is open. At viewport heights up to (650px), toolbar/control vertical padding contracts.

Controls use small gaps, with a slightly wider gap between toolbar groups. Filter chips, neighbor actions, and inspector buttons wrap. Closing the inspector reveals the canvas beneath it. Timeline mode places unpinned cards proportionally by modification date with collision lanes and a separate area for missing dates; pinned cards retain their coordinates, and switching back restores force positions.

The automatic-face row remains directly after the ordinary index strip across search, graph, Faces, and People. It is a fixed-height, non-growing flex row (44px), with compact insets (5px 18px), gaps (10px), and a fine top divider. The preference label and trailing action do not shrink; the intervening status takes the remaining width, truncates to one line, and retains the full message as its title. Busy progress is a fixed slim native bar (80 × 5px). This row adds no floating overlay or new responsive breakpoint.

The face workspace keeps the existing search and main-index context above its toolbar and local face-index strip. Its main area divides into source media and candidate review using `minmax(310px, .86fr)` and `minmax(370px, 1.14fr)`. The source has a large fitted image, numbered boxes positioned against the actual rendered image, and an auto-filling crop grid with minimum tile width (78px). Candidate review divides the list and media preview with `minmax(160px, .8fr)` and `minmax(200px, 1fr)`. Source, candidate list, and preview scroll independently; the candidate disclaimer stays below them. Repeated pane insets use the frontmatter's pane spacing.

At widths up to (940px), the face columns become `minmax(260px, .8fr)` and `minmax(310px, 1fr)`; the candidate list stacks above its preview and is capped at (200px) high. Source media is capped at (290px) high, or (230px) at that breakpoint; candidate media is capped at (240px). These are extensions of the existing desktop workspace, not new global page templates.

People divides its workspace into a (250px) directory and a flexible detail pane. The directory uses (14px 12px) insets, an independently scrolling list, and a create form below a top divider. The detail heading, wrapping observation-group controls, and status precede a result grid with `minmax(250px, 1fr)` for the list and (310px) for the preview. The selected-count and label actions stay in a separate bottom bar below that grid; the persistent local-label disclaimer follows the workspace.

At widths up to (1020px), the People directory narrows to (215px); its results become one column with shared vertical overflow, the observation list is capped at (290px), and the preview follows the list. Toolbar status, person names, rename/create forms, undo notices, and bottom actions wrap. The Undo strip sits below the toolbar in People and above the candidate bulk tools in Faces; it is a separate non-scrolling flex item.

**The Topology Rule.** Force positions communicate connections, not measured similarity distance. Timeline positions encode modification dates except for explicit pins. Show only expanded neighborhoods, retain the (120-file) cap, and do not promise planar routing for cyclic graphs.

## Elevation & Depth

Depth comes from tonal layering, translucent plates, fine strokes, and selective glow. Default file cards use a vertical gradient with top opacity (.86) and bottom opacity (.95). Floating controls, the minimap, the inspector overlay, and the context menu use backdrop blur (12px). Inspector media has no added shadow.

Face panes use flat graphite and inspector surfaces, fine dividers, and dark media backplates. Face boxes use a restrained cyan tint (`#77acc50a`) or warm hover/selected tint (`#f0a04814`) beneath their fine colored outlines. Crops, candidate rows, and source media add no decorative shadow.

People keeps those flat surfaces and fine dividers. Current-person and preview-row states use a cool tonal fill and border; fields use the inspector surface, and the Undo strip uses the cool fill with a fine bottom border. No additional shadow vocabulary is introduced.

### Shadow Vocabulary
- **Minimap lift** (`0 7px 20px #00000040`): A restrained floating-camera surface above the canvas.
- **Context menu lift** (`0 9px 28px #00000055`): Separates the temporary graph-action menu from the working canvas.
- **Selected / video glow:** SVG alpha blur with standard deviation (5), tinted amber or blue at opacity (.38). The glow sits behind the original card; it does not replace a legible border.

**The Quiet Depth Rule.** Keep default cards restrained. Selection and video state may glow; the ordinary canvas remains low contrast.

## Shapes

Horizontal file plates have gently rounded corners, while controls are slightly tighter. Thumbnails are square crops (40 × 40 world units) with smaller rounded corners. Link pills are (24 world units) high, with width (48 + 18 per modality icon) and fully rounded ends, centered at the curve midpoint with collision avoidance. The real unexpanded-neighbor count uses a smaller pill at the card's upper right; the pin affordance occupies its lower right. Strokes stay fine; keyboard focus strengthens the selected outline rather than changing the card silhouette.

Face-source stages reuse the file-card corner, face-choice and candidate rows reuse the control corner, and crops reuse the thumbnail corner. Numbered face boxes use the tighter face-box corner and a (2px) outline. Source-choice crops are (62 × 62px); candidate crops are (45 × 45px). Crop geometry comes from the indexed bounding box for the actual image or reported video frame.

People fields and directory rows reuse the control corner. Directory icons are authored outline SVGs (24px); adjacent selection checkboxes remain native square controls (15 × 15px). Observation rows reuse the candidate crop and rounded-row shape. Inline forms and action/undo strips use wrapping rectangular rows rather than floating dialogs.

The pending People badge is a small inline rounded count (8px radius), with compact padding (1px 5px) and a left gap (5px). The automatic-face row is a flat rectangular shell strip with native checkbox/progress shapes and the existing quiet action.

## Components

### Buttons

Compact glass controls use a fine neutral border, inherited native type, minimum height (34px), and the quiet/hover fills. Icon-only camera buttons are (34px) square; their outline SVG icons are (16px). Active Preview uses a stronger cool border (`#899eb1`) and active fill. Find similar uses the warm action fill and border (`#a37a49`). Confirm link and False positive use muted green/red fills, matching text, and fine state borders; Mark unverified remains quiet. Focus-visible is an amber outline (2px) with (2px) offset. Disabled graph buttons use reduced opacity (.45).

### Chips

Modality filters use compact native labels (11px), fine neutral borders, and fully rounded corners. The selected chip adopts the amber fill with warm text and border, with selection also exposed through `aria-pressed`. All, Scene, Audio, Text / OCR, and EXIF describe supported filtering. Faces opens observation selection for the current file; it is disabled until the local worker and face models are ready, with a setup explanation in its title.

### Inputs / Fields

The minimum-similarity select lives inside a rounded translucent label/control group. Its compact inner field uses `#252a30`, pale text, and tighter corners (4px). Default graph threshold is (.75); the broader (.35) and balanced (.55) options remain available. The minimap's range input uses a warm accent and a tabular numeric readout; its accessible label remains present even though visually hidden.

The graph omnibar uses a fine bordered graphite field and an amber focus-within outline. Typing filters loaded filenames and dims nonmatches to opacity (.25); Enter requests semantic highlighting on the current canvas. The result count and raw query-cosine cutoff remain visible. This input is separate from the main search field and from the edge-similarity threshold.

### Navigation

Camera navigation combines zoom out/in, Center selected, Refresh, and the Preview toggle. Drag the background or use arrow keys to pan; wheel zoom stays under the pointer. The minimap supports click/drag camera movement and keyboard panning. Use translated text and accessible labels in both RU and EN.

The Force graph / Timeline select changes the spatial view without changing the file-card material. Card pins and +N expansion affordances support keyboard activation. The temporary context menu uses the same graphite/glass material, a fine border, rounded corners (10px), and a narrow width (250px); it offers expansion, supported modalities, shortest path within the expanded graph, pin/unpin, and hiding. Its Faces entry routes to selection in the chosen file and reflects model readiness. The menu supports arrow-key navigation and Escape; hidden nodes have a restore action.

### Cards / Containers

The inspector uses a translucent tonal overlay with a fine left divider and independent vertical scrolling. Its heading and close control stay above the current file or match view. File preview, filename/path, and wrapping actions precede the Indexed evidence heading and opt-in Compute SHA-256 action. A compact two-column metadata list follows; Connected files stays collapsed initially below it. Evidence loading, a successful response with no indexed OCR, and failure with Retry have distinct text states.

Selecting a link opens side-by-side file previews and actual per-modality evidence, followed by local verification actions. Scores remain independent cosines, not probabilities or shares; exact indexed EXIF taken-date equality has no invented cosine. Seek actions are enabled only for reported media locations. File evidence explains that face observations use a separate face index and require choosing a face; unextracted objects and absent indexed OCR remain explicit. The minimap retains its translucent surface, rounded border, small shadow, collapsible heading, miniature nodes, and camera rectangle.

### Persistent Automatic Face Status

The native checkbox and Auto-index faces label persist beside a polite live status and one quiet action. A checked preference uses shell amber. The trailing action uses the shell quiet-button material and tighter padding (5px 8px), inherited native type at label size, and single-line text. Focus-visible uses shell amber (2px) with offset (2px); there is no added shadow. The row inherits the normal search shell's colors and the active workspace's graphite variables instead of globally recoloring search.

During processing, the status reports completed/total files and detected observations, appending pending-media count when available. The slim amber progress bar is determinate when the total is known and indeterminate otherwise. The action becomes Pause indexing; while cancellation is pending it is disabled. At rest, the action is Faces when models/runtime are ready, or Set up Faces otherwise. Off and paused are separate explicit messages; paused shows an unchecked preference. Waiting for ordinary indexing, preparing pending media, missing models/runtime, failed files, and errors remain text states. Errors use the existing error-text treatment, including the warm pale error text in dark and active workspaces.

Automatic processing follows ordinary indexing only after the user opts in. It uses the established local face index; this preference does not silently download models or assign person labels. Keep model setup in the explicit Faces flow and keep pause available from the persistent row.

### Local Face Index Controls

The face-index strip uses the inspector surface, compact semibold status, tabular counts, and the same native select and quiet-button shapes. It offers explicit local model download/backfill, start/resume, pause, and Auto / CPU / GPU choices. Keep active device and any CPU fallback reason readable alongside progress; changing the device is unavailable during processing. Show missing-runtime, loading, error, paused, complete, and complete-with-issues states through text. Existing unchanged observations are reused, and video sampling is stated as every (2 seconds).

### Face Observations and Candidates

The source image remains the primary context. Numbered cyan boxes and matching real crop buttons choose one observation; both expose `aria-pressed`, and the chosen source uses amber. Source labels include the actual timestamp for video observations. Loading, unprocessed, stale, no usable face, and preview failure each retain a specific explanation. Stale observations cannot be selected until reindexing.

Candidate buttons pair a real crop with filename, three-decimal cosine, and actual time when present. The inspected candidate row uses cyan fill and border. A separate preview shows its source photograph or video, cosine, reported matched-frame time, and Open / Show in Explorer / Choose another face actions. Results show loaded and total counts, a minimum-face-cosine select, and explicit pagination; index changes restart the candidate list with a visible notice. Show in graph starts from the selected face observation, not a whole-file average.

Keep the persistent language that matches are candidates rather than proof of identity, processing runs locally with YuNet + SFace, and sampled video can miss brief appearances. Cosine remains a comparison measure. The dark scrollbar track, visible thumb, and hover thumb belong to all face scrolling panes; forced-colors mode restores system scrollbar colors. Face controls use the existing amber focus outline with a (3px) offset and reduced disabled opacity (.48).

### People Directory and Local Label Forms

The directory pairs an authored person outline with a wrapping name and assigned-observation count. The current label exposes `aria-pressed` and uses the existing cyan row material. A full-width search field filters local label names; unmatched filters and an empty directory use distinct text. New-name and inline-rename fields use the same inspector fill, fine control stroke, amber caret, and existing focus outline. Names have a (120-character) input limit. Rename opens the field with focus; Cancel closes it and returns focus to Rename. Create and Save name are explicit form submissions.

Assigned, Suggestions, Excluded, and Needs review are wrapping quiet buttons in a labelled group, with `aria-pressed` and the active-preview fill/border identifying the current group. Assigned explains the operator's confirmed labels. Suggestions retains a confirmation requirement and the similarity caveat. Excluded explains that observations will not be suggested again for this person; Needs review explains changed source data and omits stale crops, source media, and open/find-faces actions.

### Pending Suggestions and Background Refresh

The People navigation action adds a compact inline badge using the inherited selected fill and shell text. A ready count uses locale-formatted numerals; a ready zero or idle summary hides the badge. Calculating shows an ellipsis and an unavailable summary shows an exclamation mark. The badge title and People accessible label explain pending person-observation suggestions or direct the operator to open People and refresh when counts are unavailable.

The People toolbar reports the same total and exposes calculating/unavailable text alongside its explicit Refresh action. Each directory label retains its assigned count and adds a secondary pending-observation line only for a positive ready count. Badge, toolbar total, and per-label pending lines share one asynchronously computed, cached summary. The total counts person-observation pairs, so one observation suggested for more than one label can contribute more than once; it is not a unique-person or unique-file count.

A ready background summary may refresh an untouched first Suggestions page. Active checkbox selection, editing, mutations/loading, an inspected preview, media playback, or later pages protect the current review and expose a readable refresh notice instead. Faces similarly offers Refresh when indexing changes source observations while preserving the current query. Preserve the incumbent independent preview highlight and bulk checkboxes; background work never confirms suggestions or silently applies labels.

### People Observation Review and Bottom Actions

Each observation has a native checkbox beside a separate candidate-style preview button. The button exposes `aria-pressed`; selecting it changes the media preview without changing the checkbox. Rows show the real crop, filename, photograph or reported video time, three-decimal cosine when supplied, and another existing label when relevant. The preview carries the filename, matched-frame or photograph explanation, and Open / Find faces actions for current observations.

The bottom bar displays Select loaded, the checked count, mode-specific label actions, and explicit Show more pagination. Suggestions offers Confirm selected and Exclude for person; Assigned offers Exclude for person and Remove label; Excluded offers Remove exclusion; Needs review offers Remove label. With no checked observations, the mutation actions are disabled. Loading, error, loaded/total, and stale-snapshot refresh messages remain text states. Person pages load (40 observations) at a time; changing the person or group clears checkbox selection and resets preview state.

### Face Labels, Bulk Scope, and Undo

The source pane adds a local-person select, Assign selected face, and a new-label form below the selected-source controls. Candidate checkboxes remain independent of the inspected cyan candidate. The bulk row offers Select loaded, All matches + source, Clear selection, a scope/count message, Assign selection, and Exclude for person. All matches + source explicitly includes unloaded matches and the source observation; unchecking rows excludes them from that scope. Changing the source, cosine threshold, or index snapshot clears bulk selection with a visible notice.

Label controls and checkboxes disable during mutations; bulk actions also disable during face search. Successful changes show local-save status and a separate wrapping Undo strip in People and Faces when an operation identifier is returned. Rename uses this same undo path. The notice carries the operation's text and any changed/conflict/stale/excluded counts supplied by the worker; mutation failures use the existing muted error text. Do not merge this strip with the persistent local-label disclaimer. RU/EN labels, selection announcements, and status messages come from the explicit catalog; user-supplied names and paths remain content.

### File Cards and Similarity Links

Each SVG file card pairs an authored media icon or local thumbnail with filename and kind. Default cards use the glass gradient, selected cards use amber fill/stroke, and unselected video cards use cyan fill/stroke. Hover raises border opacity; keyboard focus raises its width (3 world units) and uses `#ffc079`. Cards are keyboard operable with Enter or Space.

Links are smooth curves routed around cards where possible. Unverified links use a dashed pattern (6 6), with an amber-to-neutral gradient for active links. Confirmed links are solid green and wider (3 world units); explicitly shown rejected links use muted red with a shorter dotted pattern (2 7). A requested shortest path uses amber emphasis and always excludes rejected links. Manual review is an operator assessment, not an automated finding.

Centered pills pair authored modality icons with the real overall cosine to two decimals; link titles and accessible names expose three decimals and review status. Semantic-only links use the chain icon. Links have a wider transparent hit area (18 world units), and both curve and pill open match inspection; Enter or Space does the same. Focus-visible strengthens the pill border. The +N badge reports actual remaining indexed neighbors, and pin state is shown by the pin's fill.

## Do's and Don'ts

### Do:
- **Do** keep this visual system scoped to the graph, face-investigation, and People workspaces.
- **Do** preserve amber source selection and the scoped cyan video, face-box, and candidate meanings.
- **Do** pair confirmed/rejected colors with line patterns and readable local-review status.
- **Do** retain world-anchored grid, stable existing-node positions, and measured filename truncation.
- **Do** use actual local thumbnails and authored SVG icons.
- **Do** keep search/index context visible, inspector details scrollable, and camera controls keyboard accessible.
- **Do** preserve RU/EN labels, reduced-motion behavior, and forced-colors fallbacks.
- **Do** use real face crops, numbered source boxes, reported video times, and explicit paged candidate counts.
- **Do** retain local indexing/device status, visible dark scrollbars, and candidate-not-identity language in Faces.
- **Do** keep preview highlights independent of checked observations, with the selected count and label actions in the People bottom bar.
- **Do** retain explicit Assigned, Suggestions, Excluded, and Needs review groups, wrapping local-label forms, and the separate Undo strip.
- **Do** keep bulk scope visible, including unloaded matches and the source when All matches + source is active.
- **Do** retain the persistent automatic-face row, explicit preference/pause states, and file/observation progress within the existing shell.
- **Do** synchronize pending badge, toolbar, and directory counts; expose calculating/unavailable states and preserve an active review until refresh.

### Don't:
- **Don't** extend the graph palette into the desktop launcher or normal search as an implicit rebrand.
- **Don't** encode cosine as physical distance or imply that only expanded links form a complete global graph.
- **Don't** replace real scores or thumbnails with decorative fabricated data.
- **Don't** present cosine as probability, an exact EXIF-date match as provenance proof, or unavailable analysis as detected evidence.
- **Don't** use selection glow as the sole focus or state indicator.
- **Don't** present local person labels or unconfirmed suggestions as verified identities.
- **Don't** imply automatic model download, automatic person labeling, or that a pending person-observation total counts unique people or files.


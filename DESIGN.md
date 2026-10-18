---
name: DigUp Desktop Workspace
description: A shared graphite desktop shell with restrained amber actions, photo-led People albums, and local evidence workspaces.
colors:
  graphite: "#202429"
  inspector: "#252b32"
  inspector-overlay: "#252b32ed"
  media-stage: "#181c21"
  divider: "#3b434c"
  evidence-divider: "#414952"
  control-stroke: "#505962"
  search-stroke: "#46515c"
  shell-chip: "#292f36"
  shell-hover: "#2b323a"
  quiet-fill: "#323940cc"
  quiet-solid: "#323940"
  quiet-hover: "#424c57"
  active-fill: "#3a4652"
  text: "#eef2f6"
  button-text: "#e1e7ee"
  secondary-text: "#b4bec8"
  tertiary-text: "#a4aeba"
  amber: "#f0a048"
  amber-hover: "#f6b466"
  amber-ink: "#211b12"
  person-selected: "#453725"
  person-selected-stroke: "#8d673a"
  invalid-stroke: "#e3a5a1"
  error-text: "#f0cfcd"
  scrollbar-thumb: "#687785"
  scrollbar-hover: "#8999a8"
  glass-top: "#454b52"
  glass-bottom: "#2b3036"
  node-text: "#f0f2f5"
  node-secondary: "#afb8c1"
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
  modality-fill: "#293039"
typography:
  wordmark:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "25px"
    fontWeight: 600
    letterSpacing: "-0.025em"
  search:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "15px"
  person-title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "22px"
    fontWeight: 600
    letterSpacing: "-0.02em"
  drawer-title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "18px"
    fontWeight: 600
  workspace-title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "16px"
    fontWeight: 600
  period-title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "14px"
    fontWeight: 600
  body:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "13px"
  directory-name:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "13px"
    fontWeight: 500
  label:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "12px"
  explanation:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "12px"
    lineHeight: 1.65
  metadata:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "11px"
  file-name:
    fontFamily: "Segoe UI, sans-serif"
    fontSize: "14px"
    fontWeight: 500
  file-kind:
    fontFamily: "Segoe UI, sans-serif"
    fontSize: "12.5px"
rounded:
  control: "8px"
  media: "6px"
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
  group: "12px"
  large: "16px"
  gallery: "18px"
  pane: "20px"
  header-gap: "24px"
components:
  search-field:
    backgroundColor: "{colors.inspector}"
    textColor: "{colors.text}"
    typography: "{typography.search}"
    rounded: "{rounded.control}"
    padding: "0 12px"
    height: "40px"
  workspace-navigation:
    textColor: "{colors.secondary-text}"
    typography: "{typography.body}"
    padding: "0 20px"
    height: "48px"
  workspace-navigation-hover:
    backgroundColor: "{colors.shell-hover}"
    textColor: "{colors.text}"
  button-shell:
    backgroundColor: "{colors.shell-chip}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
  button-quiet:
    backgroundColor: "{colors.quiet-solid}"
    textColor: "{colors.button-text}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
  button-quiet-hover:
    backgroundColor: "{colors.quiet-hover}"
  review-tab-active:
    backgroundColor: "{colors.amber}"
    textColor: "{colors.amber-ink}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "8px 12px"
  review-tab-active-hover:
    backgroundColor: "{colors.amber-hover}"
    textColor: "{colors.amber-ink}"
  media-filter-active:
    backgroundColor: "{colors.amber}"
    textColor: "{colors.amber-ink}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
  person-directory-item-selected:
    backgroundColor: "{colors.person-selected}"
    textColor: "{colors.text}"
    rounded: "{rounded.control}"
    padding: "10px 8px"
  people-field:
    backgroundColor: "{colors.inspector}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "8px 10px"
  period-field:
    backgroundColor: "{colors.inspector}"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    rounded: "{rounded.media}"
    padding: "6px 8px"
    width: "78px"
  people-media-stage:
    backgroundColor: "{colors.media-stage}"
    rounded: "{rounded.media}"
  workspace-status:
    textColor: "{colors.text}"
    typography: "{typography.metadata}"
    padding: "0 16px"
    height: "34px"
  workspace-drawer:
    backgroundColor: "{colors.inspector}"
    textColor: "{colors.text}"
    width: "min(460px, 80vw)"
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
  button-similar:
    backgroundColor: "{colors.action-fill}"
    textColor: "{colors.action-text}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
  button-confirm:
    backgroundColor: "{colors.confirmed-fill}"
    textColor: "{colors.confirmed-text}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
  button-reject:
    backgroundColor: "{colors.rejected-fill}"
    textColor: "{colors.error-text}"
    rounded: "{rounded.control}"
    padding: "6px 10px"
  face-result-selected:
    backgroundColor: "{colors.cyan-fill}"
    textColor: "{colors.text}"
    rounded: "{rounded.control}"
    padding: "9px 6px"
---

# Design System: DigUp Desktop Workspace

## Overview

People's **Exclude similar faces…** review keeps this visual world in a bounded desktop dialog. The user
chooses a real face, adjusts the cosine threshold, reviews one portrait per matching file, then applies
one undoable correction. The complete selected-folder scope is explicit; album date filters do not narrow
the action. Square portraits use one pixel scale with a small margin, never independent X/Y stretching.
The review is 920px at most, scrolls within the viewport and wraps its footer at compact desktop widths.

Persistent negative examples and their thresholds are explicit in that review. The Excluded tab contains
a compact expandable list of saved rules, with source portraits when available and an action to allow
future suggestions while retaining individual rejections. Every visible person in the directory has a
current confirmed cover when available. Cover DOM nodes survive count updates; layout and scroll trigger
bounded image loading without hover. Placeholder person icons mean there is no current confirmed cover.

**Creative North Star: "Graphite Media Workspace"**

DigUp's Windows/Linux Tauri HTML shell uses a shared dark graphite world for Search, Graph, People, and contextual face investigation. Restrained warm amber identifies current actions and selections; quiet native sans text, fine separators, and spacious working areas keep local files and photographs primary. This records the user-approved expansion of the earlier graph system. The separate native macOS application has its own implementation.

People is a photo-led library: choose a local label, choose an inclusive year interval, then browse whole media. A slim two-handle rail and precise fields give the period a useful visual signature. One compact background-task footer keeps work visible; index details, language, and automatic-face settings open in a drawer. Actual local crops, filenames, dates, and counts supply the content.

Graph retains its established glass file plates, world grid, modality cues, and evidence review colors. Faces retains source-led media, numbered detections, real crops, and separate candidate review. These established evidence materials coexist with the flatter shared chrome.

**Key Characteristics:**
- Shared graphite search header, three main destinations, and contextual face action.
- Warm current-person selection, neutral counts, and uncropped album photographs.
- Two inclusive year endpoints, native range handles, and explicit date provenance.
- One compact background-task footer with on-demand detail and settings.
- Graph evidence colors and independent preview/bulk-selection states.
- Native sans, authored SVG icons, RU/EN copy, keyboard focus, and desktop reflow.

Source authority is the stylesheet order in shell/ui/index.html: panel.css, graph.css, graph-investigation.css, faces.css, people.css, then workspace.css. The last sheet establishes the shared palette and updated composition; the earlier sheets still supply scoped components and higher-specificity state rules. Markup and behavior are in index.html, people.js, and panel.js; graph cards are built in graph.js. The approved .impeccable/mocks/people-period/b-timeline.png and its approved sidecar establish composition, not fictional data or exact screenshot reproduction. This document records current source after the material correction batch; it does not certify the fidelity gate or release checks.

## Colors

Graphite neutrals recede behind photographs. Amber is a restrained working accent; evidence colors retain their scoped meanings.

### Primary

- **Amber:** The orange Up in the wordmark, active destination icon/underline, active review/media controls, year interval and handles, caret, and keyboard focus.
- **Warm current label:** A muted warm fill and fine warm stroke identify the selected People directory row. The actual album count remains neutral.
- **Amber hover and ink:** Selected People controls lighten on hover and keep dark text for legibility.

### Secondary

- **Cyan:** Unselected graph video cards, available face boxes, and inspected candidate/observation rows. The current People directory label uses the warm current-label treatment instead.
- **Confirmed / rejected:** Green and muted red encode explicit graph review. Confirmed links are solid; rejected links use a dotted pattern and appear only when requested. Green also marks idle index status in the compact footer.
- **Error:** Pale warm error text and a distinct invalid-field stroke support visible recovery messages.

### Neutral

- **Graphite / inspector:** The main field and its slightly raised controls/drawer. Shared separators use the divider token; legacy evidence panes retain their evidence-divider token.
- **Text / secondary / tertiary:** Main labels, supporting metadata, and quiet status detail. Counts and dates use neutral text with tabular numerals.
- **Media stage:** Dark neutral mats preserve the complete image across portrait and landscape sources.
- **Glass / quiet controls:** Graph plates retain their gradient stops. Face and People quiet actions use solid tonal fills; graph actions use the translucent variant.
- **Scrollbar:** Visible muted thumbs and brighter hover thumbs on dark tracks.

**The State Color Rule.** Amber follows current shell and People actions and the selected graph/source observation. Cyan keeps its scoped video, face-box, and inspected-candidate meanings. Graph review colors retain their explicit text and line-pattern evidence.

**The Separate Selection Rule.** A candidate or observation highlight chooses a preview. A native checkbox chooses observations for label actions. Preview selection never implies a checked observation or confirmed identity.

## Typography

**Body Font:** The native sans stack in the frontmatter is a deliberate desktop commitment. Windows uses Segoe UI Variable Text/Segoe UI when available; Linux falls through to its available native sans faces. No downloaded display font is required.

**Graph Label Font:** SVG filenames and kinds use Segoe UI with a sans-serif fallback, matching their measured text geometry.

The wordmark is compact semibold text with tight tracking: Dig uses the primary text color and Up uses amber. The person heading is the strongest album label; the adjacent file count stays smaller and neutral. The search field, period heading, workspace/drawer headings, native control text, and metadata have distinct roles in the frontmatter rather than one display scale. The empty Search heading is (24px), semibold with tight tracking. Explanation popovers use the explanation role; ordinary Faces explanatory text uses (12px) with line-height (1.5). Footers, year ticks, and dates use the metadata role, with tabular numerals where values change.

At the desktop breakpoints the wordmark reduces to (22px), then (20px). Long local label names and notices wrap. Album filenames use a single-line ellipsis; full media context is available in the viewer. Graph filenames use measured middle ellipsis to preserve both beginning and ending, with full paths available in the inspector.

**The Content Type Rule.** Keep names, paths, counts, dates, and scores readable through wrapping, appropriate truncation, and accessible context; preserve the native type hierarchy rather than shrinking content to fit.

## Layout

The shared panel is a full-height flex column. Its search header is (64px) high with broad search (40px), horizontal insets (20px), and a separate settings control. The mode row is (48px) high: Search, Graph, and People lead; contextual Find faces sits at the right. The single background-task footer is (34px) high. View-specific result summaries and investigation evidence notes retain their own purpose.

The settings/index drawer overlays the right side of the working view between top (112px) and bottom (34px), with width capped by min(460px, 80vw). It scrolls vertically and groups language, main-index detail, automatic-face preference/progress, and index statistics. Opening it keeps the album visible. Escape closes the drawer and returns focus to its trigger.

People uses a (230px) directory and a flexible detail pane. The directory has (18px 14px) insets and an independent scrolling list. The heading uses (20px 20px 10px) insets, followed by wrapping review tabs. The period section uses (12px 20px 8px), wrapping precise fields, a (30px) native-handle region, year ticks, provenance hint, and any error. Its height follows content and desktop wrapping; the mock's nominal (90px) is not a fixed source height. Media filters, loaded/total count, and date sort share a wrapping row. The gallery has four columns above the reflow breakpoint, (18px) gaps, and (20px) horizontal insets. Its cells use (4:3) media stages, fitted complete photographs, and captions beneath.

At widths up to (1100px), People uses a (200px) directory, a gallery with auto-filled minimum (170px) columns, (14px) gaps, and tighter period control gaps. At widths up to (800px), the directory becomes (180px), gallery minimum columns become (145px), header/nav/footer insets contract, and the optional compact suggestion action is hidden. Controls wrap rather than clip. Normal and wide desktop composition targets are (1280px) and (1586px); the compact desktop target is (780px). These are desktop CSS/DIP widths, not mobile claims or proof that the latest captures passed.

Observation review retains its list/preview split; up to (1020px) it stacks with the list capped at (290px). Faces keeps source and candidate panes; up to (940px), the candidate list stacks above its preview and is capped at (200px). The source image cap changes from (290px) to (230px). Source, result, and evidence panes scroll independently.

Graph retains a clipped flexible canvas, a right overlay inspector (360px), and a minimap (160px) with its own camera controls. The inspector has (14px) insets and a (180px) file preview. The world grid repeats at (48 units); file cards are (244 × 72 units). Camera movement preserves topology. The (1050px) breakpoint wraps graph controls; at (700px) the inspector width is capped at canvas width minus (24px) and an open inspector hides the minimap. Short desktop heights up to (650px) tighten graph toolbar spacing.

**The Topology Rule.** Graph force positions communicate connections, not measured similarity distance. Graph timeline positions encode modification dates except for explicit pins. Keep the (120-file) cap and actual expansion scope visible.

## Elevation & Depth

Shared shell and People surfaces are flat and separated by tone and fine strokes. Photo mats and captions carry no decorative lift. The information popover uses an inspector fill, border, and bounded scrollable region; the settings drawer adds the source's soft left shadow. Its reveal runs for (160ms) with cubic-bezier(.16,1,.3,1) only when reduced motion is not requested.

Graph retains its scoped depth: gradient file plates with top opacity (.86) and bottom opacity (.95), backdrop blur (12px) on floating evidence controls, and selected/video SVG glow with blur standard deviation (5) and opacity (.38). Faces uses flat panes and fine cyan/warm detection tints.

- **Drawer shadow:** -12px 0 30px #00000035 separates on-demand detail from the working area.
- **Minimap shadow:** 0 7px 20px #00000040 separates camera controls from the canvas.
- **Context menu shadow:** 0 9px 28px #00000055 separates temporary file actions.

**The Quiet Depth Rule.** Shared chrome and album cells remain flat. Graph's existing plate depth and selection/video glow serve its evidence scene; they are scoped materials rather than a reason to decorate every control.

## Shapes

Controls and directory rows use small rounded corners. Year fields, selected directory crops, and album media use the tighter media corner. Main search uses the control corner. The native window keeps its platform treatment: the Windows HTML panel uses (8px), while the generic panel uses (18px); native clipping owns the outer silhouette.

Shared header icon controls are (36px) square with (20px) SVGs. Selected directory crops are (38px) square when available. Year handles use circular amber thumbs with a graphite (2px) border: WebKit defines a (14px) thumb and Gecko a (12px) thumb. The rail track and selected interval are (2px) high. Face-source crops remain (62px), candidate crops (45px), and numbered face boxes use a (2px) outline with the face-box corner. Bulk-selection checkboxes remain native (15px) square controls.

Graph file plates use the file-card corner; score pills use rounded ends and authored modality icons. The pending badge uses the control corner with compact (1px 5px) padding. The full-media viewer uses the file-card corner and leaves (16px) outside each edge, with width capped at (1600px).

## Components

### Search and navigation

Ordinary Search reuses the People year rail below navigation and adds the same quiet **All / Photos / Videos** choices. The shared `YearPeriodControl` owns endpoint validation, native number/range keyboard behavior and rail drawing; each view retains its own saved preferences. With no query, an explicit date/media filter browses indexed files by date and labels the preview as an indexed file. Code and related-file views hide the rail. The People full-media viewer adds **Find similar** beside its existing Open and Find faces actions; its return action restores the person and album preferences. These additions preserve the incumbent shell tokens and responsive breakpoints.

The text wordmark, broad bordered search, clear action, and settings gear share the first row. Search focus changes the field border to amber. The three main destinations retain visible text and authored outline SVG icons. Current navigation has semibold text, amber icon, and a (3px) underline; hover adds the shell-hover fill and primary text. Disabled navigation uses opacity (.45). The contextual face action remains available independently of the three destinations.

### Buttons, fields, and review controls

Quiet shell actions use shell-chip; People/Faces actions use quiet-solid, fine control stroke, and compact padding. Graph actions use the translucent quiet fill and minimum height (34px). Quiet People/Faces hover uses quiet-hover. The People review group has Gallery, Face annotations, Suggestions, Excluded, and Needs review. Inactive tabs are transparent with secondary text; the active tab and active media filter use amber with dark ink and lighten on hover. Selection is also exposed through aria-pressed.

People name/filter fields use inspector fill, control stroke, native type, and amber caret. Year fields are narrower and use their own radius/padding. Invalid endpoints use invalid-stroke and a visible error paragraph with role="alert"; an invalid interval keeps the prior album. Values accept inclusive years (1–9999), and blank endpoints remain open. Native range controls offer the same two endpoints and accessible year labels. The rail has real year bounds and ticks, without invented statistical bars.

Focus-visible uses a (2px) amber outline. People/Faces fields and controls use offset (3px), graph controls and base shell buttons use offset (2px), and range inputs use offset (1px). Native disabled controls remain distinguishable; People/Faces controls use opacity (.48), the gallery sort (.5), and inherited shell controls (.6). Forced-colors rules preserve system evidence/focus affordances where implemented.

### People directory, gallery, and information

Saved People names/counts warm in the background at launch. Directory loading is exposed with aria-busy and a localized empty-list loading message; warm data renders immediately while current counts are revalidated. The viewer footer keeps keyboard guidance at the left and a separate **Exclude from this album** action at the right, wrapping at narrow desktop widths. It corrects one person's file membership, closes to the gallery on success and retains existing Undo. Busy state disables viewer navigation/actions; errors remain visible in the viewer. The settings gear uses a symmetric eight-tooth outline and a concentric center in the existing 24px icon grid.

The selected local label uses person-selected fill and person-selected-stroke. Its current real crop appears when the loaded gallery/assigned page supplies one; other states keep an authored outline person icon. Names wrap, while assigned and pending counts remain secondary. Create and inline Rename are explicit forms with a (120-character) name limit and Cancel/focus recovery.

The gallery uses actual whole photographs or video previews fitted with object-fit: contain. Cells show filenames, media type, and available dates. File-modification fallbacks add a visible source label; accessible labels and date titles also state provenance. Capture date is preferred when valid and indexed. Media type, inclusive period, and date sort apply to the complete album before pagination. Empty filters offer a reset path; failed previews retain a specific message. Hover changes the caption filename to amber. The dialog viewer preserves whole-media fitting, previous/next controls, Open, Find faces, and Close.

The small information details affordance beside the title contains the local-label identity caveat and the complete latest operation notice. Its popover has a maximum height (45vh), bounded width, and scrolling. Escape closes it before leaving People and returns focus to its summary. Successful saves announce through a visually hidden live region; errors remain visible. The successful-save toolbar is hidden, preserving the photo-led working area. Undo remains a separate wrapping action strip when an operation can be reversed.

### Compact status and detailed settings

The footer exposes main-index status, current face work/progress, pending suggestions when present, and Details. A small dot and readable text convey stage; busy face progress uses a native (70 × 4px) bar. Clicking status, face progress, settings, or Details opens the same drawer. Detailed automatic-face preference, pause/setup action, full progress text, and diagnostic statistics live inside it; they are not a second persistent shell band. The drawer's automatic-face row wraps and keeps the full message readable. Existing opt-in behavior, explicit pause, local processing, and model setup remain product constraints.

### Graph evidence and Faces review

File cards retain actual thumbnails/authored icons, measured filenames, kind labels, amber selected state, and cyan unselected-video state. Unverified links are dashed (6 6); confirmed links are solid green (3 world units); rejected links use a short pattern (2 7). Similarity pills show actual cosine, with finer precision and review status in accessible/inspector context. The inspector distinguishes indexed evidence, missing analysis, loading, error, and local verification. The graph omnibar, modality chips, camera controls, minimap, context menu, pins, and explicit neighbor expansion remain separate operations.

Faces keeps the large source photograph/frame, numbered cyan detections, warm selected source/crop, and a cyan inspected candidate. Real crops, actual video times, explicit loaded/total counts, and the candidate-not-identity explanation remain visible. Native bulk checkboxes remain independent of preview. Assigned, Suggestions, Excluded, and Needs review keep their explicit label semantics and mode-specific bottom actions. Background index changes preserve active review and offer refresh. Undo and scope text include actual worker outcomes, conflicts, and stale counts where supplied.

## Do's and Don'ts

### Do:

- **Do** use the shared graphite shell for Search, Graph, People, and contextual Faces on Windows/Linux.
- **Do** retain the white Dig / amber Up wordmark and restrained amber active states.
- **Do** keep photographs whole, dates explicit, counts neutral, and year endpoints inclusive.
- **Do** keep media filters, gallery count, and sort together in one wrapping control row.
- **Do** keep background detail in the drawer and local-label explanations in the information affordance.
- **Do** preserve graph evidence colors, world grid, glass plates, actual scores, and line-pattern review cues.
- **Do** keep preview highlights separate from checked bulk selections and unconfirmed suggestions.
- **Do** preserve RU/EN text, native keyboard operation, focus recovery, reduced motion, and implemented forced-colors behavior.

### Don't:

- **Don't** substitute mock portraits, names, counts, years, or metadata for actual local content.
- **Don't** crop album photographs into face thumbnails or hide file-date fallback provenance behind hover alone.
- **Don't** add persistent success/explanation bands above the album or restore a second background-status strip.
- **Don't** extend a graph-specific evidence color into a new global meaning without an explicit product decision.
- **Don't** present local labels, cosine, or matching capture dates as proof of identity or provenance.
- **Don't** turn desktop reflow targets into mobile support or claim a fidelity/release check that has not passed.


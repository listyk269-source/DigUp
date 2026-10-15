---
name: DigUp Graph Workspace
description: Graph-scoped graphite canvas with glass file cards and amber/cyan state cues.
colors:
  graphite: "#202429"
  inspector: "#252b32"
  inspector-overlay: "#252b32ed"
  glass-top: "#454b52"
  glass-bottom: "#2b3036"
  quiet-fill: "#323940cc"
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
typography:
  title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", system-ui, Ubuntu, Cantarell, "Noto Sans", sans-serif'
    fontSize: "16px"
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
spacing:
  compact: "6px"
  control-gap: "7px"
  small: "8px"
  medium: "10px"
  large: "16px"
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
---

# Design System: DigUp Graph Workspace

## Overview

**Creative North Star: "Graphite, Glass, Amber/Cyan"**

This system applies only to DigUp's Tauri graph workspace and its graph-active shell colors. It records the implemented interpretation of the user's pinned dark canvas reference. The desktop launcher, normal search layout, setup flow, and other native surfaces retain their incumbent design; these graph tokens are not a product-wide rebrand.

A restrained graphite canvas supports compact translucent horizontal file cards. Amber identifies the selected file and emphasizes its unverified incident links; cyan distinguishes video cards. Green and muted red record the operator's confirmed and rejected link states. Authored outline icons and actual local thumbnails carry file identity. The canvas remains dense enough for exploration while the overlay inspector supplies readable file and match evidence.

**Key Characteristics:**
- A world-anchored grid and stable file neighborhoods.
- Glass plates with small rounded corners and restrained state glows.
- Native sans typography, measured filename truncation, and modality/cosine pills.
- Visible search/index context, graph search and filters, a collapsible evidence inspector, and an operable minimap.

Source of truth: `shell/ui/graph.css`, its extension `shell/ui/graph-investigation.css`, SVG construction in `shell/ui/graph.js`, investigation behavior in `shell/ui/graph-tools.js` and `shell/ui/graph-state.js`, markup in `shell/ui/index.html`, and RU/EN strings in `shell/ui/i18n.js`. Corrected native WebView captures of file evidence, match comparison, timeline, context menu, and documents confirm the composition at (1280 × 900 DIP); synthetic fixture content is evidence of rendering, not brand imagery. `docs/graph-investigation.md` records the evidence and capability boundaries.

## Colors

Cool graphite neutrals establish the working surface; warm selection and cool video cues explain state without coloring every file.

### Primary
- **Amber:** Selected-card outline, keyboard focus, minimap selection, and selected-file link emphasis. The selected fill and label soften the same warm state.
- **Warm Action:** The Find similar action uses a muted warm fill and pale warm text rather than a saturated banner.

### Secondary
- **Cyan:** Video-card outlines and the corresponding cool fill/metadata. Selected video cards adopt the amber selection state.

### Tertiary
- **Confirmed Green:** Solid confirmed links, their pill borders, and the Confirm link action. This records a local human assessment.
- **Rejected Red:** Rejected links when Show rejected is enabled and the False positive action. Rejected links are hidden by default.

### Neutral
- **Graphite:** Canvas, score-label backplates, and graph-active outer background.
- **Inspector / Inspector Overlay:** The explanatory footer and translucent file/match evidence overlay.
- **Glass Top / Glass Bottom:** The default file plate's vertical translucent gradient.
- **Quiet Fill / Quiet Hover / Active Fill:** Compact controls and their interaction states.
- **Control Stroke / Divider:** Functional boundaries between controls, canvas, inspector, and footer.
- **Text / Secondary Text:** General graph text and supporting status information.
- **Node Text / Node Secondary:** File names and file-kind labels.
- **Modality Fill:** Quiet modality chips and link-pill backplates.

**The State Color Rule.** Amber follows the selected card, active unverified links, and a requested shortest path. Cyan identifies unselected video cards. Confirmed links retain green during ordinary selection; rejected links use muted red only when explicitly shown. Pair review colors with line patterns and inspector text.

## Typography

**Body Font:** The inherited native sans stack in the frontmatter.
**Graph Label Font:** Segoe UI with a sans-serif fallback.

**Character:** A compact utility hierarchy serves filenames, metadata, and controls. There is no display type role in this graph surface.

### Hierarchy
- **Title:** Graph heading, with a semibold weight.
- **File Name:** Medium-weight file identity inside the card; fit to a measured text width (166 world units) using a middle ellipsis.
- **File Kind:** Supporting type label below the file name.
- **Body:** Inspector explanation and footer note; the inspector title is semibold at the file-name size.
- **Label:** Buttons, threshold controls, status, neighboring-file actions, and cosine scores.
- **Metadata:** Paths, minimap heading, and zoom readout. Scores and zoom values use tabular numerals.

**The Filename Rule.** Preserve the filename's beginning and ending when truncating. Keep full paths available through the card title and inspector instead of shrinking the type.

## Layout

The graph occupies a vertically stacked workspace below the existing search field and index status. A heading/status/omnibar/back row sits above threshold and camera controls, modality filters, layout selection, and concise feedback. A flexible clipped canvas fills the main area; an independently scrolling inspector overlays its right side. The explanatory note stays below the workspace.

The graph window requests up to (1280 × 900 DIP), clamped to the monitor work area. Leaving graph restores the search window's (780 DIP) width. Canvas coordinates are world units: cards are (244 × 72), with hard separation of (320 × 124). Force relaxation and radial anchors arrange new neighbors while existing nodes stay pinned between expansions. Camera movement does not rerun layout.

The canvas grid repeats every (48 world units). Initial camera zoom is (75%); controls support (20–200%). The minimap is (160px) wide and sits (16px) from the lower edge; its right inset becomes (376px) while the inspector is open. The inspector is (360px) wide with (14px) internal padding and a (180px) file preview. It remains that width through the compact toolbar breakpoint (1050px). At widths up to (700px), its width is capped at the canvas width minus (24px), and the minimap is hidden while the overlay is open. At viewport heights up to (650px), toolbar/control vertical padding contracts.

Controls use small gaps, with a slightly wider gap between toolbar groups. Filter chips, neighbor actions, and inspector buttons wrap. Closing the inspector reveals the canvas beneath it. Timeline mode places unpinned cards proportionally by modification date with collision lanes and a separate area for missing dates; pinned cards retain their coordinates, and switching back restores force positions.

**The Topology Rule.** Force positions communicate connections, not measured similarity distance. Timeline positions encode modification dates except for explicit pins. Show only expanded neighborhoods, retain the (120-file) cap, and do not promise planar routing for cyclic graphs.

## Elevation & Depth

Depth comes from tonal layering, translucent plates, fine strokes, and selective glow. Default file cards use a vertical gradient with top opacity (.86) and bottom opacity (.95). Floating controls, the minimap, the inspector overlay, and the context menu use backdrop blur (12px). Inspector media has no added shadow.

### Shadow Vocabulary
- **Minimap lift** (`0 7px 20px #00000040`): A restrained floating-camera surface above the canvas.
- **Context menu lift** (`0 9px 28px #00000055`): Separates the temporary graph-action menu from the working canvas.
- **Selected / video glow:** SVG alpha blur with standard deviation (5), tinted amber or blue at opacity (.38). The glow sits behind the original card; it does not replace a legible border.

**The Quiet Depth Rule.** Keep default cards restrained. Selection and video state may glow; the ordinary canvas remains low contrast.

## Shapes

Horizontal file plates have gently rounded corners, while controls are slightly tighter. Thumbnails are square crops (40 × 40 world units) with smaller rounded corners. Link pills are (24 world units) high, with width (48 + 18 per modality icon) and fully rounded ends, centered at the curve midpoint with collision avoidance. The real unexpanded-neighbor count uses a smaller pill at the card's upper right; the pin affordance occupies its lower right. Strokes stay fine; keyboard focus strengthens the selected outline rather than changing the card silhouette.

## Components

### Buttons

Compact glass controls use a fine neutral border, inherited native type, minimum height (34px), and the quiet/hover fills. Icon-only camera buttons are (34px) square; their outline SVG icons are (16px). Active Preview uses a stronger cool border (`#899eb1`) and active fill. Find similar uses the warm action fill and border (`#a37a49`). Confirm link and False positive use muted green/red fills, matching text, and fine state borders; Mark unverified remains quiet. Focus-visible is an amber outline (2px) with (2px) offset. Disabled graph buttons use reduced opacity (.45).

### Chips

Modality filters use compact native labels (11px), fine neutral borders, and fully rounded corners. The selected chip adopts the amber fill with warm text and border, with selection also exposed through `aria-pressed`. All, Scene, Audio, Text / OCR, and EXIF describe supported filtering; Faces stays visibly disabled because this build has no face analyzer.

### Inputs / Fields

The minimum-similarity select lives inside a rounded translucent label/control group. Its compact inner field uses `#252a30`, pale text, and tighter corners (4px). Default graph threshold is (.75); the broader (.35) and balanced (.55) options remain available. The minimap's range input uses a warm accent and a tabular numeric readout; its accessible label remains present even though visually hidden.

The graph omnibar uses a fine bordered graphite field and an amber focus-within outline. Typing filters loaded filenames and dims nonmatches to opacity (.25); Enter requests semantic highlighting on the current canvas. The result count and raw query-cosine cutoff remain visible. This input is separate from the main search field and from the edge-similarity threshold.

### Navigation

Camera navigation combines zoom out/in, Center selected, Refresh, and the Preview toggle. Drag the background or use arrow keys to pan; wheel zoom stays under the pointer. The minimap supports click/drag camera movement and keyboard panning. Use translated text and accessible labels in both RU and EN.

The Force graph / Timeline select changes the spatial view without changing the file-card material. Card pins and +N expansion affordances support keyboard activation. The temporary context menu uses the same graphite/glass material, a fine border, rounded corners (10px), and a narrow width (250px); it offers expansion, supported modalities, shortest path within the expanded graph, pin/unpin, and hiding. Disabled Faces remains explicit. The menu supports arrow-key navigation and Escape; hidden nodes have a restore action.

### Cards / Containers

The inspector uses a translucent tonal overlay with a fine left divider and independent vertical scrolling. Its heading and close control stay above the current file or match view. File preview, filename/path, and wrapping actions precede the Indexed evidence heading and opt-in Compute SHA-256 action. A compact two-column metadata list follows; Connected files stays collapsed initially below it. Evidence loading, a successful response with no indexed OCR, and failure with Retry have distinct text states.

Selecting a link opens side-by-side file previews and actual per-modality evidence, followed by local verification actions. Scores remain independent cosines, not probabilities or shares; exact indexed EXIF taken-date equality has no invented cosine. Seek actions are enabled only for reported media locations. Unavailable face/object analysis and absent indexed OCR are stated honestly. The minimap retains its translucent surface, rounded border, small shadow, collapsible heading, miniature nodes, and camera rectangle.

### File Cards and Similarity Links

Each SVG file card pairs an authored media icon or local thumbnail with filename and kind. Default cards use the glass gradient, selected cards use amber fill/stroke, and unselected video cards use cyan fill/stroke. Hover raises border opacity; keyboard focus raises its width (3 world units) and uses `#ffc079`. Cards are keyboard operable with Enter or Space.

Links are smooth curves routed around cards where possible. Unverified links use a dashed pattern (6 6), with an amber-to-neutral gradient for active links. Confirmed links are solid green and wider (3 world units); explicitly shown rejected links use muted red with a shorter dotted pattern (2 7). A requested shortest path uses amber emphasis and always excludes rejected links. Manual review is an operator assessment, not an automated finding.

Centered pills pair authored modality icons with the real overall cosine to two decimals; link titles and accessible names expose three decimals and review status. Semantic-only links use the chain icon. Links have a wider transparent hit area (18 world units), and both curve and pill open match inspection; Enter or Space does the same. Focus-visible strengthens the pill border. The +N badge reports actual remaining indexed neighbors, and pin state is shown by the pin's fill.

## Do's and Don'ts

### Do:
- **Do** keep this visual system scoped to graph mode.
- **Do** preserve the amber selection and cyan video meanings.
- **Do** pair confirmed/rejected colors with line patterns and readable local-review status.
- **Do** retain world-anchored grid, stable existing-node positions, and measured filename truncation.
- **Do** use actual local thumbnails and authored SVG icons.
- **Do** keep search/index context visible, inspector details scrollable, and camera controls keyboard accessible.
- **Do** preserve RU/EN labels, reduced-motion behavior, and forced-colors fallbacks.

### Don't:
- **Don't** extend the graph palette into the desktop launcher or normal search as an implicit rebrand.
- **Don't** encode cosine as physical distance or imply that only expanded links form a complete global graph.
- **Don't** replace real scores or thumbnails with decorative fabricated data.
- **Don't** present cosine as probability, an exact EXIF-date match as provenance proof, or unavailable analysis as detected evidence.
- **Don't** use selection glow as the sole focus or state indicator.


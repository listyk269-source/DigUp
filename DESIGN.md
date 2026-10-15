---
name: DigUp Graph Workspace
description: Graph-scoped graphite canvas with glass file cards and amber/cyan state cues.
colors:
  graphite: "#202429"
  inspector: "#252b32"
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
  score: "4px"
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

A restrained graphite canvas supports compact translucent horizontal file cards. Amber identifies the selected file and its incident links; cyan distinguishes video cards. Authored outline icons and actual local thumbnails carry file identity. The canvas remains dense enough for exploration while the inspector supplies readable detail.

**Key Characteristics:**
- A world-anchored grid and stable file neighborhoods.
- Glass plates with small rounded corners and restrained state glows.
- Native sans typography, measured filename truncation, and numeric similarity labels.
- Visible search/index context, a collapsible inspector, and an operable minimap.

Source of truth: `shell/ui/graph.css`, SVG construction in `shell/ui/graph.js`, markup in `shell/ui/index.html`, and RU/EN strings in `shell/ui/i18n.js`. Corrected native WebView captures confirm the composition; synthetic fixture content is evidence of rendering, not brand imagery.

## Colors

Cool graphite neutrals establish the working surface; warm selection and cool video cues explain state without coloring every file.

### Primary
- **Amber:** Selected-card outline, keyboard focus, minimap selection, and selected-file link emphasis. The selected fill and label soften the same warm state.
- **Warm Action:** The Find similar action uses a muted warm fill and pale warm text rather than a saturated banner.

### Secondary
- **Cyan:** Video-card outlines and the corresponding cool fill/metadata. Selected video cards adopt the amber selection state.

### Neutral
- **Graphite:** Canvas, score-label backplates, and graph-active outer background.
- **Inspector:** Preview rail and explanatory footer.
- **Glass Top / Glass Bottom:** The default file plate's vertical translucent gradient.
- **Quiet Fill / Quiet Hover / Active Fill:** Compact controls and their interaction states.
- **Control Stroke / Divider:** Functional boundaries between controls, canvas, inspector, and footer.
- **Text / Secondary Text:** General graph text and supporting status information.
- **Node Text / Node Secondary:** File names and file-kind labels.

**The State Color Rule.** Amber follows the selection and its incident links. Cyan identifies video when that card is unselected. Preserve these meanings when adding graph states.

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

The graph occupies a vertically stacked workspace below the existing search field and index status. A heading/status/back row sits above threshold and camera controls. The main area divides into a flexible, clipped canvas and an independently scrolling inspector; the explanatory note stays below both.

The graph window requests up to (1280 × 900 DIP), clamped to the monitor work area. Leaving graph restores the search window's (780 DIP) width. Canvas coordinates are world units: cards are (244 × 72), with hard separation of (320 × 124). Force relaxation and radial anchors arrange new neighbors while existing nodes stay pinned between expansions. Camera movement does not rerun layout.

The canvas grid repeats every (48 world units). Initial camera zoom is (75%); controls support (20–200%). The minimap sits (16px) from the canvas's lower/right edges and is (190px) wide. The inspector is (286px) wide with (16px) internal padding; at viewport widths up to (1050px) it becomes (250px). The toolbar wraps as needed. At viewport heights up to (650px), preview height falls from (200px) to (130px), and toolbar/control vertical padding contracts.

Controls use small gaps, with a slightly wider gap between toolbar groups. Neighbor actions and inspector buttons wrap instead of extending the rail. The inspector can collapse to return width to the canvas.

**The Topology Rule.** Position communicates connections, not measured similarity distance. Show only expanded neighborhoods, retain the (120-file) cap, and do not promise planar routing for cyclic graphs.

## Elevation & Depth

Depth comes from tonal layering, translucent plates, fine strokes, and selective glow. Default file cards use a vertical gradient with top opacity (.86) and bottom opacity (.95). Floating controls and the minimap use backdrop blur (12px). Inspector media has no added shadow.

### Shadow Vocabulary
- **Minimap lift** (`0 7px 20px #00000040`): A restrained floating-camera surface above the canvas.
- **Selected / video glow:** SVG alpha blur with standard deviation (5), tinted amber or blue at opacity (.38). The glow sits behind the original card; it does not replace a legible border.

**The Quiet Depth Rule.** Keep default cards restrained. Selection and video state may glow; the ordinary canvas remains low contrast.

## Shapes

Horizontal file plates have gently rounded corners, while controls are slightly tighter. Thumbnails are square crops (40 × 40 world units) with smaller rounded corners. Similarity labels use a compact rounded backplate (42 × 20 world units), positioned in a route gap. Strokes stay fine; keyboard focus strengthens the selected outline rather than changing the card silhouette.

## Components

### Buttons

Compact glass controls use a fine neutral border, inherited native type, minimum height (34px), and the quiet/hover fills. Icon-only camera buttons are (34px) square; their outline SVG icons are (16px). Active Preview uses a stronger cool border (`#899eb1`) and active fill. Find similar uses the warm action fill and border (`#a37a49`). Focus-visible is an amber outline (2px) with (2px) offset. Disabled buttons inherit reduced opacity (.6).

### Inputs / Fields

The minimum-similarity select lives inside a rounded translucent label/control group. Its compact inner field uses `#252a30`, pale text, and tighter corners (4px). Default graph threshold is (.75); the broader (.35) and balanced (.55) options remain available. The minimap's range input uses a warm accent and a tabular numeric readout; its accessible label remains present even though visually hidden.

### Navigation

Camera navigation combines zoom out/in, Center selected, Refresh, and the Preview toggle. Drag the background or use arrow keys to pan; wheel zoom stays under the pointer. The minimap supports click/drag camera movement and keyboard panning. Use translated text and accessible labels in both RU and EN.

### Cards / Containers

The inspector uses a solid tonal surface with a fine left divider and independent vertical scrolling. Preview and file details stack above wrapping actions and a single-column neighbor list. The minimap uses a translucent surface, rounded border, small shadow, collapsible heading, miniature nodes, and a camera rectangle.

### File Cards and Similarity Links

Each SVG file card pairs an authored media icon or local thumbnail with filename and kind. Default cards use the glass gradient, selected cards use amber fill/stroke, and unselected video cards use cyan fill/stroke. Hover raises border opacity; keyboard focus raises its width (3 world units) and uses `#ffc079`. Cards are keyboard operable with Enter or Space.

Links are smooth curves routed around cards where possible. Default links are thin and muted; selected-file links become wider, more opaque amber-to-neutral gradients. Display real cosine values to two decimals on the canvas; the link title exposes three decimals. Labels have canvas-colored backplates, tabular numerals, and no pointer interaction.

## Do's and Don'ts

### Do:
- **Do** keep this visual system scoped to graph mode.
- **Do** preserve the amber selection and cyan video meanings.
- **Do** retain world-anchored grid, stable existing-node positions, and measured filename truncation.
- **Do** use actual local thumbnails and authored SVG icons.
- **Do** keep search/index context visible, inspector details scrollable, and camera controls keyboard accessible.
- **Do** preserve RU/EN labels, reduced-motion behavior, and forced-colors fallbacks.

### Don't:
- **Don't** extend the graph palette into the desktop launcher or normal search as an implicit rebrand.
- **Don't** encode cosine as physical distance or imply that only expanded links form a complete global graph.
- **Don't** replace real scores or thumbnails with decorative fabricated data.
- **Don't** use selection glow as the sole focus or state indicator.


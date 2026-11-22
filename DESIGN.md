---
name: DigUp Windows file search preview
description: A light desktop workspace based on the user's installed Listary 7.1.0.47 file search window.
colors:
  chrome: "#eef4fd"
  paper: "#fbfcfe"
  selection: "#dce8ff"
  accent: "#2766cf"
  ink: "#1e2430"
  muted: "#555e6b"
---

# Desktop file search

The visual reference for this branch is the Russian File Search Window of the installed Listary 7.1.0.47. Its light window stays light on the reference machine with Windows apps set to dark. The normal DigUp entry point, worker protocol, rounded native frame and scoped local search remain the basis of the preview. The shared theme is in `shell/ui/desktop-theme.css`.

## Search

A compact title row contains the DigUp mark and the Search, Graph and People destinations. The full-width query sits below it, on pale chrome with a blue bottom edge. The query retains focus during arrow navigation. Enter opens a file and Ctrl+Enter reveals it in its folder on Windows.

The left rail holds the actual media and date predicates. Documents covers documents and PDFs, Images covers pictures and screenshots. The existing inclusive year range uses capture dates when available and otherwise file dates. Date provenance is visible beside the controls.

The detail list uses the Windows system sans, 13 px file names, 12 px metadata, and a 28 px minimum row. Columns show file name, parent path, size and modification time. File size and date columns yield space as the list narrows. Matched text is blue; the selected row has a pale blue background. The path cell keeps its last folder visible. Keyword excerpts and segment labels retain their place in the matching row.

The bottom-right preview button and Alt+P open and close the selected file's inspector. The preference is saved locally. The initial full-width list mirrors the reference file window. Search messages remain visible with an empty result set. Index progress stays in the status strip and its existing details drawer.

## Graph, People and Faces

The shared window chrome, active states, separators, focus rings and control surfaces carry across all workspaces. Graph cards use pale surfaces, a blue selected outline, distinct video and review colors, the existing line patterns, real counts and scores. Keep the minimap, per-node actions, inspector, explicit neighbor expansion and file-version checks. Graph snapshot SVGs carry their own theme values.

People keeps saved labels, year controls, review states and its gallery of whole photographs. Face matches remain suggestions. Retain independent bulk selection, undo, real media, video moments and label provenance. Native folder setup, device selection and first-run steps use the same light palette. The user can review the packaged Windows preview before the release branch adopts it.

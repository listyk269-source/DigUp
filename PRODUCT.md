# DigUp

<!-- impeccable:product-schema 1 -->

## Platform

web

Desktop web UI hosted by Tauri on Windows and Linux. The separate macOS native app must remain compatible.

## Users

People searching their own local documents and media, exploring content similarities, and organizing labelled photographs and videos into People albums.

## Product Purpose

Find local files by meaning, text, content relationships, or a selected face without a cloud account. A labelled person's complete album should be quickly accessible without repeating face inference.

## Operating Context

Local, potentially large multilingual media collections on Windows 10/11. Background indexing, face backfill, and search coexist. Files, annotations, and settings remain on the user's machine.

## Capabilities and Constraints

Existing search, graph investigation, local YuNet/SFace face search, People labels, suggestions, rejection, rename, undo, paged galleries, whole-media viewer, and optional automatic face indexing must remain available. EXIF capture dates already indexed take precedence over file modification dates for album periods; absent or invalid capture dates fall back to file dates. Period filters operate on the whole album before pagination. Do not fabricate diagnostics, identity certainty, or metadata. No new cloud services or telemetry.

## Brand Commitments

The user confirmed dark graphite, a restrained orange accent, separate Search / Graph / People navigation, generous working space, and compact status with expandable details. Rounded native window corners remain. Russian and English interfaces remain supported. The user explicitly chose mockups before implementation for this redesign.

## Product Principles

- Keep working content visible while background tasks run.
- Make saved albums fast and complete, with explicit date provenance.
- Give progress, recovery actions, and detailed diagnostics distinct places.
- Treat face matches as suggestions and names as local user labels.

## Evidence on Hand

Existing native packaged screenshots and public NASA media smoke fixtures. Personal media must not be used for tests or design assets. The supplied UX audit is reference material; example counts in it are not product data.

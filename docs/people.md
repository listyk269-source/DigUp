# People and local face labels

People is a local annotation layer on the existing YuNet/SFace face index. Labels are names chosen
by the user, not identities discovered by the model. No labels, pictures or face descriptors are
uploaded. Original media and their EXIF are not modified.

## Label a face and its matches

1. Finish ordinary indexing and the optional [face backfill](face-search.md). Open a photograph or
   video in **Faces** and select one outlined face or face crop.
2. Choose an existing person or create a label. Adjust the face similarity threshold and review
   the matches. Select individual observations, or choose all matches.
3. All matches includes observations on pages that have not been loaded, plus the source face.
   Exclude incorrect observations before applying. Changing the query invalidates the old selection;
   changed index revisions require refreshing before a bulk action.
4. Apply explicitly. One observation can have one confirmed person label. Bulk operations do not
   silently overwrite another person's confirmed observations; conflicts are reported. All-matches
   assignment preserves previous rejections for that person. An explicit selected assignment can
   restore a rejected observation when the user changes their decision.

Labels belong to the particular face in a photograph or frame, not every person in the file.
Several observations of the same video can retain their separate matched timestamps.

## Browse and correct People

Open **People** from the search header. Filter labels by name and open a person to browse their
confirmed observations. Real crops, original previews, file opening and video timestamps remain
available. Rename the person without running inference again.

Assigned albums open directly from saved labels, without scanning every face descriptor or starting
YuNet/SFace again. The directory shows both unique file counts and labelled observations: several
faces or video frames in one file are not several photographs. The first page contains 40 observations;
scrolling near its end automatically loads the next page. **Show more** remains available for keyboard
navigation. There is no 40-file limit. Checked rows and the current preview remain in place while paging.

Only visible and nearby album thumbnails are requested, with two concurrent requests. Generated
previews are reused across restarts in `<index>/preview-cache-v1`, with version/frame/size-specific
keys and eviction at approximately 512 MiB or 20,000 JPEGs (checked after each 64 new entries).
These disposable local JPEGs are not encrypted; deleting this cache while DigUp is closed is safe
and does not remove labels or the index. Missing, changed or out-of-scope sources cannot be opened
through a cached preview. Original images remain unchanged.

Remove a label to leave the observation unassigned. **This is another person** records an explicit
rejection for that person and observation, so the same suggestion is suppressed. Rejected
observations can be reviewed separately. These decisions do not remove files or face descriptors.

The undo action restores the most recent annotation operation, including a bulk change or rename.
It is transactional and persisted across restarts. Another annotation mutation makes an older undo
token expire; it cannot overwrite more recent corrections. Ordinary indexing does not silently
turn proposals into confirmed labels.

## Suggestions for new media

After face search has been enabled, new or changed media enter the face queue automatically when
ordinary indexing finishes each file. Keep DigUp running; no separate face-index button is required.
The compact status row reports automatic file/frame progress and offers a persistent pause/resume
checkbox. Existing face users are opted into this continuation; users who have never enabled face
search must first download the verified models explicitly. Automatic work never downloads models.

The People badge and directory report pending suggestions. The total counts person-observation
pairs: one face proposed to two labels counts twice, and separate video timestamps count separately.
It is not a count of unique people or files. While counts are being recalculated the UI says so
instead of showing an old number as current. Confirming or rejecting proposals updates the count.

Open the person's **Suggestions** to review the automatically indexed media.
Candidates are compared against confirmed examples from that person using compatible SFace
vectors. Comparison uses a deterministic sample of at most 64 actual confirmed descriptors across
the examples, so confirming a long video cannot turn proposal generation into an unbounded all-pairs
comparison. This is a speed/coverage tradeoff; the sample can miss a rare appearance. All manual labels
remain stored. Proposed matches are not additional reference examples until explicitly accepted.
Confirm selected suggestions or reject mistakes. Rejections remain effective on refresh/restart.
No new model download or face inference is needed merely to browse existing labels or matches.

Automatic jobs reuse completed exact file versions/configurations. New files arriving during a job
are coalesced into a later pass. Cancel/pause stops owned decoders and inference and remains paused
after restarting DigUp. Resuming rechecks pending media; malformed exact versions do not cause a
continuous retry loop. Explicit manual indexing remains available to retry an unsuccessful file.
Missing models/runtime and unavailable folders are reported without automatic network access.
New media still require the ordinary index watcher to publish them first. Changed, removed and
out-of-scope observations do not inherit a confirmed label or remain in current proposal counts.

## Storage and changes to files

People uses an additive migration of `face-index.sqlite`; the semantic index and existing face
observations are preserved. Labels and their revision/history are local to this index and OS account.
They are not additionally encrypted. Back up the sidecar, its SQLite companions and `face-auto.json`
with DigUp closed. The JSON file stores automatic preferences and failed exact-version attempts;
removing the face database alone does not disable an already-enabled automatic scheduler.

Annotations bind an exact model, file version and face observation. Reprocessing the same observation
can reconnect it to its annotation despite a new database row ID. A changed or missing observation
is retained for stale-record review instead of being silently assigned to different contents.
Current results and all bulk actions respect selected folders, exclusions and current file versions.
Files outside the selected scope do not become visible through People.

Cosines are similarity measures, not identity probabilities. Uniform video sampling, small-face and
codec limitations from [face search](face-search.md#accuracy-and-limits) still apply. This feature does
not implement automatic naming, unsupervised person clustering or forensic identity verification.

## Reproduce the native workflow check

```powershell
. ./scripts/windows/Enter-Environment.ps1
./scripts/windows/Build.ps1 -Jobs 4
node --test Tests/GraphModelTests.cjs Tests/GraphInvestigationTests.cjs Tests/FaceStateTests.cjs Tests/PeopleStateTests.cjs Tests/I18nTests.cjs
./scripts/windows/Faces-Smoke.ps1 -People -Archive build.noindex/windows/artifacts/DigUp-windows-x64-portable.zip -Models C:/test-models -OutputDirectory C:/test-evidence/people
./scripts/windows/Automatic-Faces-Smoke.ps1 -Archive build.noindex/windows/artifacts/DigUp-windows-x64-portable.zip -Models C:/test-models -OutputDirectory C:/test-evidence/automatic-faces
```

Use a fresh evidence directory and real pinned models. The smoke uses public NASA media in an isolated
Unicode directory, the packaged GUI/helper and a system-only PATH. It labels actual face observations,
then adds new photographs through the real ordinary index and face backfill before checking proposals
and restart persistence. It does not replace face inference or the native media player with mocks.
The People phases also verify actual automatic scrolling past 40, decoded later-page photographs,
deferred offscreen thumbnails and preserved DOM/media elements when checking observations.
The automatic smoke additionally copies a real photograph and H.264 video while the GUI is running.
The native filesystem watcher, ordinary indexer and background face scheduler must publish their
actual observations without a `face_start` request. It verifies progress, proposal counts after
accept/reject, persisted pause, resume, files added while stopped and idle stability.
Unsigned builds and clean Windows 10/11 installation checks retain the [Windows release gates](windows.md).

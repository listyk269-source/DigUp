// The search panel of DigUp's Windows and Linux shell (tried out on the Mac first). Every keystroke shows keyword
// results at once (the last word as a prefix); once typing pauses for 120 ms the meaning results replace them (the
// query was embedded while you typed). Results far weaker than the best are folded under "N weaker matches". The
// helper (`digup search-service`) does the work; the Mac app's panel (Sources/DigUpApp/SearchPanel.swift) is the
// reference for how it behaves.
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const ask = (request) => invoke("ask", { request });
const fileURL = (path) => tauri.core.convertFileSrc(path);

const TYPING_PAUSE = 120;          // ms after the last keystroke until the meaning results show
const PAGE_SIZE = 40;
const FIELD_HEIGHT = 56;
const INDEX_HEIGHT = 80;
const FACE_AUTO_HEIGHT = 44;
const PANEL_HEIGHT = 560;
const WEAKER = "\u0000weaker";     // the selectable row that folds and unfolds the weaker matches
const isMac = /Mac/.test(navigator.platform);
const isWindows = /Win/.test(navigator.platform);
document.documentElement.classList.toggle("platform-windows", isWindows);
const MOD = isMac ? "⌘" : "Ctrl+";
const fileManager = () => isMac ? "Finder" : isWindows ? (I18n.language === "ru" ? "Проводнике" : "Explorer") : t("Files");
// Pictures every web view shows as they are; anything else (HEIC, TIFF, RAW…) comes as JPEG from the helper.
const SHOWN_AS_IS = new Set(["jpg", "jpeg", "png", "gif", "webp", "bmp"]);
const GROUP_OF = { screenshot: "Screenshots", image: "Images", pdf: "Documents", doc: "Documents", video: "Video",
                   audio: "Audio", code: "Code" };
const KIND_TITLE = { screenshot: "Screenshot", image: "Image", pdf: "PDF", doc: "Document", audio: "Audio",
                     video: "Video", code: "Code" };

const $ = (id) => document.getElementById(id);
const $query = $("query"), $body = $("body"), $list = $("list"), $preview = $("preview");
const $footer = $("footer"), $summary = $("summary"), $keys = $("keys");
const $indexStatus = $("index-status"), $indexTitle = $("index-title"), $indexCount = $("index-count");
const $indexDetail = $("index-detail"), $indexProgress = $("index-progress");

const state = {
  generation: 0,
  finalGeneration: -1,   // the generation whose meaning results are showing: late keyword results don't replace them
  timer: null,
  phase: "empty",        // empty | words | meaning | wordsOnly | codeHint
  text: "",              // what was searched (without "code:")
  isCode: false,
  strong: [],
  weaker: [],
  groups: [],
  showWeaker: false,
  selection: null,       // a result's path, or WEAKER
  navigated: false,      // the arrow keys moved the selection since the last edit
  encoder: "stopped",
  height: FIELD_HEIGHT,
  home: "",
  error: null,
  indexing: null,
  indexStatus: null,     // replayable Rust snapshot of real index-service events
  page: null,
  loadingMore: false,
  pageError: null,
  related: null,
  statsOpen: false,
  stats: null,
  statsGeneration: 0,
};
let debugPending = false;
const progressHistory = [];
let progressQueued = false;
let debugOptions = {};
const featureReport = {};
let facesReturnGraph = false;
const graph = new GraphView({ ask, invoke, nameOf, thumbnailFor: graphThumbnail, previewFor: (hit, code) => picture(hit, { code, query: "" }), onSimilar: findSimilar, onVisibility: (visible) => {
  if (visible && people.visible) people.close();
  if (visible && faceSearch.visible) faceSearch.close(false);
  if (visible) state.statsOpen = false;
  render();
}, onFaces: (hit) => openFaces(hit) });
const faceSearch = new FaceSearchView({ ask, invoke, rendered, fileURL, picture, nameOf, clock, onVisibility: (visible, restore) => {
  if (visible) {
    if (people.visible) people.close();
    if (graph.visible) { facesReturnGraph = true; graph.close(); }
    state.statsOpen = false;
  } else {
    if (restore && facesReturnGraph) { graph.visible = true; graph.render(); }
    facesReturnGraph = false;
  }
  render();
}, onGraph: (seed, reply, minimum) => graph.showFaceMatches(seed, reply, minimum) });
window.faceSearch = faceSearch;
const people = new PeopleView({ ask, faceSearch, invoke, picture, nameOf, clock, onVisibility: (visible) => {
  if (visible) { if (faceSearch.visible) faceSearch.close(false); if (graph.visible) graph.close(); state.statsOpen = false; }
  render();
}, onFace: (hit) => openFaces(hit) });
window.people = people;
function openFaces(hit = selectedHit()) { return faceSearch.openTask = faceSearch.open(hit); }
const debugPages = [];

// MARK: Searching

function queryChanged() {
  if (people.visible) people.close();
  if (faceSearch.visible) faceSearch.close(false);
  if (graph.visible || graph.loading) graph.close();
  state.related = null;
  const generation = ++state.generation;
  clearTimeout(state.timer);
  state.navigated = false;
  state.error = null;
  state.page = null;
  state.loadingMore = false;
  state.pageError = null;
  const typed = $query.value.trim();
  const code = /^code:/i.test(typed);
  const text = code ? typed.slice(5).trim() : typed;
  state.isCode = code;
  if (text) state.statsOpen = false;
  renderPaging();
  if (!typed || (code && !text)) {
    show({ hits: [], strong: 0 }, text, typed ? "codeHint" : "empty");
    return;
  }
  // Keep the bounded keyword preview cheap on every keystroke. Complete, paged
  // retrieval starts after typing pauses, even if the model is unavailable.
  ask({ op: "search", q: text, code, meaning: false, prefix_last: true, limit: PAGE_SIZE })
    .then((reply) => {
      if (generation === state.generation && state.finalGeneration !== generation) show(reply, text, "words");
    })
    .catch((error) => { if (generation === state.generation) failed(error); });
  // The meaning is embedded now, so its vector is ready when typing pauses: the pause is the whole wait.
  ask({ op: "embed_ahead", q: text, code }).catch(() => {});
  state.timer = setTimeout(() => {
    ask({ op: "search_page", q: text, code, meaning: true, limit: PAGE_SIZE })
      .then((reply) => {
        if (generation !== state.generation) return;
        state.finalGeneration = generation;
        show(reply, text, reply.meaning ? "meaning" : "wordsOnly");
        if (debugPending) completeDebugSearch().catch(failed);
      })
      .catch((error) => { if (generation === state.generation) failed(error); });
  }, TYPING_PAUSE);
}

function show(reply, text, phase) {
  if (reply.ok === false) { failed(reply.error); return; }
  const hits = reply.hits || [];
  const strong = Math.min(reply.strong ?? hits.length, hits.length);
  state.text = text;
  state.phase = phase;
  state.strong = hits.slice(0, strong);
  state.weaker = hits.slice(strong);
  // Grouped by kind, the best hit's group first; code is one group with the room of all of them.
  const groups = new Map();
  for (const hit of state.strong) {
    const title = GROUP_OF[hit.kind] || "Files";
    if (!groups.has(title)) groups.set(title, []);
    groups.get(title).push(hit);
  }
  state.groups = [...groups].map(([title, rows]) => ({ title, rows, total: rows.length }));
  state.page = reply.cursor ? { cursor: reply.cursor, offset: reply.next_offset, total: reply.total, hasMore: reply.has_more } : null;
  if (!state.navigated) state.showWeaker = false;
  // Follow the top hit until you pick something with the arrow keys.
  const ids = rowIDs();
  if (!state.navigated || !ids.includes(state.selection)) state.selection = ids[0] ?? null;
  render();
}

async function loadMore() {
  const page = state.page;
  if (!page?.hasMore || state.loadingMore) return;
  const generation = state.generation;
  state.loadingMore = true;
  state.pageError = null;
  renderPaging();
  try {
    const reply = await ask(state.related
      ? { op: "related_files", ...state.related.request, offset: page.offset, limit: PAGE_SIZE }
      : { op: "search_page", cursor: page.cursor, offset: page.offset, limit: PAGE_SIZE });
    if (state.related && reply.ok !== false) {
      reply.cursor = page.cursor; reply.strong = (reply.hits || []).length;
      if (reply.vector_source !== state.related.source) throw new Error(t("The index model changed. Start a new graph."));
    }
    if (generation !== state.generation || state.page?.cursor !== page.cursor) return;
    if (reply.ok === false) { state.pageError = reply.error; state.page.expired = !!reply.expired; return; }
    const seen = new Set([...state.strong, ...state.weaker].map((hit) => hit.path));
    const hits = (reply.hits || []).filter((hit) => !seen.has(hit.path) && seen.add(hit.path));
    const strong = hits.filter((hit) => (reply.hits || []).indexOf(hit) < reply.strong);
    const weaker = hits.filter((hit) => !strong.includes(hit));
    const selected = state.selection, scroll = $list.scrollTop;
    state.navigated = true;
    if (weaker.length) state.showWeaker = true;
    show({ ...reply, hits: [...state.strong, ...strong, ...state.weaker, ...weaker], strong: state.strong.length + strong.length }, state.text, state.phase);
    state.selection = selected;
    $list.scrollTop = scroll;
  } catch (error) {
    if (generation === state.generation) state.pageError = String(error.message || error);
  } finally {
    if (generation === state.generation) { state.loadingMore = false; renderPaging(); renderFooter(); }
  }
}

async function findSimilar(seed, code = state.isCode) {
  if (!seed) return;
  if (graph.visible) graph.close();
  const previous = state.related?.previous ?? { value: $query.value, selection: state.selection };
  const generation = ++state.generation;
  clearTimeout(state.timer);
  state.finalGeneration = generation;
  state.related = { seed, previous, request: { path: seed.path, segment: seed.segment_id, code, minimum_cosine: 0.55 } };
  state.isCode = code; state.statsOpen = false; state.error = null; state.loadingMore = false; state.pageError = null;
  state.strong = []; state.weaker = []; state.groups = []; state.page = null; state.selection = null;
  state.phase = "similar"; state.text = ""; render();
  $("similar-title").textContent = t("Finding related files…");
  try {
    const reply = await ask({ op: "related_files", ...state.related.request, offset: 0, limit: PAGE_SIZE });
    if (generation !== state.generation) return;
    if (reply.ok === false) throw new Error(t(reply.error));
    state.related.source = reply.vector_source;
    // Keep the same matched-fragment/file-mean basis for subsequent pages.
    if (reply.basis === "file_mean") delete state.related.request.segment;
    state.navigated = false;
    show({ ...reply, cursor: `related-${generation}`, strong: reply.hits.length }, "", "similar");
  } catch (error) { if (generation === state.generation) failed(error); }
}
function backFromSimilar() {
  const previous = state.related?.previous;
  if (!previous) return;
  $query.value = previous.value; queryChanged(); $query.focus();
}

function renderPaging() {
  const page = state.page;
  $("more-controls").hidden = !page?.hasMore;
  $("load-more").disabled = state.loadingMore;
  $("load-more").textContent = state.loadingMore ? t("Loading…") : page?.expired ? t("Refresh results") : t("Show more");
  $("page-status").textContent = (state.pageError ? t(state.pageError) : null) || (page ? t("{loaded} of {total} matches loaded", { loaded: state.strong.length + state.weaker.length, total: page.total.toLocaleString(I18n.locale()) }) : "");
}

async function refreshStats() {
  const generation = ++state.statsGeneration;
  $("stats-refresh").disabled = true;
  $("stats-message").textContent = t("Loading index statistics…");
  try {
    const reply = await ask({ op: "index_stats" });
    if (generation !== state.statsGeneration) return;
    if (reply.ok === false) throw new Error(reply.error);
    state.stats = reply;
    const kinds = new Map(), totals = { searchable: 0, pending: 0, partial: 0, failed: 0, skipped: 0, raw: 0, bytes: 0, vectors: 0, segments: 0 };
    for (const index of reply.indexes || []) {
      for (const [kind, states] of Object.entries(index.by_kind_and_state || {})) {
        const row = kinds.get(kind) || { searchable: 0, pending: 0, issues: 0 };
        row.searchable += (states.done || 0) + (states.partial || 0);
        row.pending += states.pending || 0;
        row.issues += (states.failed || 0) + (states.skipped || 0);
        kinds.set(kind, row);
        totals.searchable += (states.done || 0) + (states.partial || 0);
        for (const key of ["pending", "partial", "failed", "skipped"]) totals[key] += states[key] || 0;
      }
      totals.raw += index.unsupported_raw || 0;
      for (const key of ["bytes", "vectors", "segments"]) totals[key] += index[key] || 0;
    }
    const n = (value) => value.toLocaleString(I18n.locale());
    $("stats-totals").replaceChildren();
    for (const [label, value] of [[t("Searchable files"), n(totals.searchable)], [t("Waiting to index"), n(totals.pending)],
      [t("Long files still being read"), n(totals.partial)], [t("Unsupported RAW files"), n(totals.raw)],
      [t("Other failed files"), n(Math.max(0, totals.failed - totals.raw))], [t("Skipped files"), n(totals.skipped)],
      [t("Indexed fragments / vectors"), `${n(totals.segments)} / ${n(totals.vectors)}`],
      [t("Database storage (including retained files)"), formatBytes(totals.bytes)]]) {
      $("stats-totals").append(element("dt", "", label), element("dd", "", value));
    }
    $("stats-kinds").replaceChildren();
    for (const [kind, values] of [...kinds].sort((a, b) => b[1].searchable - a[1].searchable || a[0].localeCompare(b[0]))) {
      const row = element("tr", "");
      row.append(element("th", "", t(KIND_TITLE[kind] || kind)));
      for (const key of ["searchable", "pending", "issues"]) row.append(element("td", "", n(values[key])));
      $("stats-kinds").append(row);
    }
    $("stats-recent").replaceChildren();
    const recent = (reply.indexes || []).flatMap((index) => index.recent || [])
      .sort((a, b) => b.indexed_at - a.indexed_at).slice(0, 6);
    for (const file of recent) {
      const button = element("button", "", nameOf(file.path));
      button.type = "button";
      button.title = file.path;
      button.onclick = () => invoke("open_path", { path: file.path }).catch((error) => { $("stats-message").textContent = String(error); });
      $("stats-recent").append(button);
    }
    $("stats-message").textContent = kinds.size ? t("{count} selected folders · {status}", { count: n(reply.folders + reply.code_folders), status: state.indexStatus?.stage === "idle" ? t("Watching for changes") : t("Indexing status shown above") }) : t("No files in the selected folders have reached the index yet.");
    if (!recent.length) $("stats-recent").append(element("p", "overview-note", t("No indexed files yet.")));
    const latest = Math.max(0, ...(reply.indexes || []).map((index) => index.last_indexed || 0));
    $("stats-stamp").textContent = t("Updated {time}", { time: new Date(reply.sampled_at * 1000).toLocaleTimeString(I18n.locale()) })
      + (latest ? t(" · Last file indexed {time}", { time: new Date(latest * 1000).toLocaleString(I18n.locale()) }) : "")
      + t(". Counts cover selected folders; database storage covers the whole saved index.");
  } catch (error) {
    if (generation === state.statsGeneration) $("stats-message").textContent = t("Statistics unavailable: {error}. Try Refresh.", { error: t(String(error.message || error)) });
  } finally {
    if (generation === state.statsGeneration) $("stats-refresh").disabled = false;
  }
}

function formatBytes(value) {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MiB`;
}

function failed(error) {
  state.error = String(error.message || error);
  renderFooter();
  if (debugPending) report();
}

function rowIDs() {
  return [
    ...state.groups.flatMap((group) => group.rows.map((hit) => hit.path)),
    ...(state.weaker.length ? [WEAKER] : []),
    ...(state.showWeaker ? state.weaker.map((hit) => hit.path) : []),
  ];
}

function selectedHit() {
  return [...state.strong, ...state.weaker].find((hit) => hit.path === state.selection) ?? null;
}

function move(step) {
  const ids = rowIDs();
  if (!ids.length) return;
  const index = ids.indexOf(state.selection);
  state.selection = ids[Math.max(0, Math.min(ids.length - 1, (index < 0 ? -1 : index) + step))];
  state.navigated = true;
  render();
}

function toggleWeaker() {
  state.showWeaker = !state.showWeaker;
  state.selection = WEAKER;
  render();
}

function openSelected() {
  const hit = selectedHit();
  if (hit) invoke("open_path", { path: hit.path }).catch(failed);
}

function revealSelected() {
  const hit = selectedHit();
  if (hit) invoke("reveal", { path: hit.path }).catch(failed);
}

// MARK: Drawing

function render() {
  const empty = state.phase === "empty";
  const facesVisible = faceSearch.visible;
  const peopleVisible = people.visible;
  document.querySelector(".panel").classList.toggle("graph-active", graph.visible);
  document.querySelector(".panel").classList.toggle("faces-active", facesVisible);
  document.documentElement.classList.toggle("graph-mode", graph.visible);
  document.documentElement.classList.toggle("faces-mode", facesVisible);
  document.querySelector(".panel").classList.toggle("people-active", peopleVisible);
  document.documentElement.classList.toggle("people-mode", peopleVisible);
  const height = graph.visible || facesVisible || peopleVisible ? 900 : empty && !state.statsOpen ? FIELD_HEIGHT + INDEX_HEIGHT + FACE_AUTO_HEIGHT : PANEL_HEIGHT;
  if (height !== state.height) {
    state.height = height;
    invoke("panel_height", { height, graph: graph.visible || facesVisible || peopleVisible }).catch(() => {});
  }
  $body.hidden = empty || state.statsOpen || graph.visible || facesVisible || peopleVisible;
  $footer.hidden = empty || state.statsOpen || graph.visible || facesVisible || peopleVisible;
  $("graph-view").hidden = !graph.visible;
  $("faces-view").hidden = !facesVisible;
  $("faces-toggle").setAttribute("aria-expanded", String(facesVisible));
  $("people-view").hidden = !peopleVisible;
  $("people-toggle").setAttribute("aria-expanded", String(peopleVisible));
  $("similar-context").hidden = !state.related || graph.visible || state.statsOpen || facesVisible || peopleVisible;
  $("similar-title").textContent = state.related ? t("Similar to {name}", { name: nameOf(state.related.seed.path) }) : "";
  $("graph-toggle").disabled = !selectedHit();
  $("graph-toggle").setAttribute("aria-expanded", String(graph.visible));
  $("index-overview").hidden = !state.statsOpen;
  $("stats-toggle").setAttribute("aria-expanded", String(state.statsOpen));
  renderPaging();
  if (empty) return;
  renderList();
  renderPreview();
  renderFooter();
}

function renderList() {
  $list.replaceChildren();
  const nothing = !state.strong.length && !state.weaker.length;
  $list.hidden = nothing;
  if (nothing) return;
  for (const group of state.groups) {
    $list.append(element("div", "group-title", t(group.title)));
    for (const hit of group.rows) $list.append(row(hit));
  }
  if (state.weaker.length) {
    const fold = element("div", "weaker" + (state.showWeaker ? " open" : "") + (state.selection === WEAKER ? " selected" : ""));
    fold.innerHTML = ICONS.chevron;
    const count = state.weaker.length;
    fold.append(state.showWeaker ? t("Weaker matches") : t("{count} weaker matches", { count }));
    fold.onclick = toggleWeaker;
    $list.append(fold);
    if (state.showWeaker) for (const hit of state.weaker) $list.append(row(hit));
  }
  $list.querySelector(".selected")?.scrollIntoView({ block: "nearest" });
}

function row(hit) {
  const item = element("div", "row" + (state.selection === hit.path ? " selected" : ""));
  item.setAttribute("role", "option");
  item.append(thumbnail(hit));
  const text = element("div", "row-text");
  const title = element("div", "row-title");
  title.append(element("span", "name", nameOf(hit.path)));
  const place = placeOf(hit);
  if (place) title.append(element("span", "badge", place));
  const sub = element("div", "row-sub");
  // The words found, where keyword search found them; else where the file is.
  if (hit.excerpt && hit.excerpt.includes("«")) sub.innerHTML = marked(hit.excerpt);
  else sub.textContent = folderOf(hit);
  text.append(title, sub);
  item.append(text);
  item.onclick = () => {
    state.selection = hit.path;
    state.navigated = true;
    render();
  };
  item.ondblclick = openSelected;
  return item;
}

/// A picture of the file for its row: the picture itself, a video's frame at the moment, a PDF's page; else its
/// kind's icon. All come small from the helper (a full-size photo per row would cost the web view hundreds of MB).
function thumbnail(hit) {
  const pixels = Math.round(36 * (window.devicePixelRatio || 1));
  const what = hit.kind === "image" || hit.kind === "screenshot" ? ["image", null]
    : hit.kind === "video" ? ["video", hit.loc ?? 0.5]
    : hit.kind === "pdf" ? ["pdf", hit.segment === "page" || hit.segment === "page_image" ? hit.loc : 1]
    : null;
  if (!what) return kindIcon(hit.kind);
  const image = element("img", "thumb");
  image.alt = "";
  rendered(hit.path, what[0], what[1], pixels)
    .then((path) => { image.src = fileURL(path); })
    .catch(() => image.replaceWith(kindIcon(hit.kind)));
  return image;
}

function renderPreview() {
  $preview.replaceChildren();
  if (!state.strong.length && !state.weaker.length) {
    if (state.phase === "codeHint") {
      $preview.append(message(t("Search your code"), t("Say what the code does, or type a name that's in it.")));
    } else if (state.indexing) {
      $preview.append(message(t("Nothing yet"), t("Still indexing. Until a file is read, DigUp finds it only by its name.")));
    } else if (state.isCode) {
      $preview.append(message(t("No good matches in your code"), t("Try saying what the code does, or a name that's in it.")));
    } else {
      $preview.append(message(t("No good matches"), t("Try what you'd see or hear in it, or words you remember from it.")));
    }
    return;
  }
  if (state.selection === WEAKER) {
    const count = state.weaker.length;
    $preview.append(message(state.showWeaker ? t("Weaker matches") : t("{count} weaker matches", { count }),
      t("They match much less well than the results above. Press Return to {action}.", { action: state.showWeaker ? t("fold them away") : t("show them") })));
    return;
  }
  const hit = selectedHit();
  if (!hit) return;
  $preview.append(picture(hit), facts(hit));
}

/// The big picture: the photo or screenshot, the frame at the moment (it plays from there), the page, what's heard
/// at the moment, or the passage that matched.
function picture(hit, { code = state.isCode, query = state.text } = {}) {
  const frame = element("div", "picture");
  const image = element("img");
  image.alt = "";
  const unavailable = () => { frame.dataset.previewState = "unavailable"; frame.replaceChildren(element("p", "preview-unavailable", t("Preview unavailable. Open the file in its default app."))); };
  // A late thumbnail failure must not remove a player that the user already opened.
  image.onerror = () => { if (!frame.querySelector("video,audio")) unavailable(); };
  frame.append(image);
  switch (hit.kind) {
    case "image":
    case "screenshot":
      if (SHOWN_AS_IS.has(extensionOf(hit.path))) image.src = fileURL(hit.path);
      else rendered(hit.path, "image", null, 1024).then((path) => { image.src = fileURL(path); }).catch(unavailable);
      return frame;
    case "pdf":
      rendered(hit.path, "pdf", hit.loc ?? 1, 1024).then((path) => { image.src = fileURL(path); }).catch(unavailable);
      return frame;
    case "video": {
      // The frame at the moment, its time on it; a click plays the video from there.
      const at = hit.loc ?? 0;
      rendered(hit.path, "video", at, 1024).then((path) => { image.src = fileURL(path); }).catch(() => { if (!frame.querySelector("video")) unavailable(); });
      const moment = element("div", "moment");
      const play = element("div", "play");
      play.innerHTML = ICONS.play;
      moment.append(image, play, element("span", "at", clock(at)));
      frame.replaceChildren(moment);
      frame.onclick = () => {
        if (frame.querySelector("video")) return;
        const video = element("video");
        frame.dataset.mediaState = "loading"; delete frame.dataset.mediaErrorCode; delete frame.dataset.mediaError;
        video.onerror = () => {
          frame.dataset.mediaState = "error";
          frame.dataset.mediaErrorCode = String(video.error?.code ?? 0);
          frame.dataset.mediaError = video.error?.message || "Native media decoder failed";
          video.pause(); unavailable();
        };
        video.onloadedmetadata = () => { frame.dataset.mediaState = "metadata"; };
        video.onloadeddata = () => { frame.dataset.mediaState = "ready"; };
        video.controls = true;
        video.autoplay = true;
        frame.replaceChildren(video);
        video.src = `${fileURL(hit.path)}#t=${at}`;
      };
      return frame;
    }
    case "audio": {
      const audio = element("div", "audio-picture");
      audio.innerHTML = ICONS.audio;
      const player = element("audio");
      player.src = `${fileURL(hit.path)}#t=${hit.loc ?? 0}`;
      player.onerror = unavailable;
      player.controls = true;
      player.preload = "metadata";
      audio.append(player);
      frame.replaceChildren(audio);
      return frame;
    }
    default: {
      const passage = element("div", "passage" + (hit.kind === "code" ? " code" : ""));
      passage.textContent = (hit.excerpt ?? t("Loading preview…")).replace(/[«»]/g, "");
      ask({ op: "text", segment: hit.segment_id, path: hit.path, code })
        .then((reply) => { if (reply.text) passage.innerHTML = highlighted(reply.text, query);
          else if (!hit.excerpt) passage.textContent = t("Preview unavailable. Open the file in its default app."); })
        .catch(() => { if (!hit.excerpt) passage.textContent = t("Preview unavailable. Open the file in its default app."); });
      return passage;
    }
  }
}

function facts(hit) {
  const box = element("div", "facts");
  box.append(element("div", "title", nameOf(hit.path)), element("div", "line", folderOf(hit)),
             element("div", "line", details(hit)));
  const reason = element("div", "reason");
  reason.innerHTML = ICONS.found;
  reason.append(element("span", "", reasonOf(hit)));
  box.append(reason);
  if (hit.excerpt && hit.excerpt.includes("«") && hit.kind !== "doc" && hit.kind !== "code") {
    const words = element("div", "reason-text");
    words.innerHTML = marked(hit.excerpt);
    box.append(words);
  }
  const buttons = element("div", "buttons");
  const open = element("button", "", t("Open"));
  open.onclick = openSelected;
  const reveal = element("button", "", t("Show in {manager}", { manager: fileManager() }));
  reveal.onclick = revealSelected;
  const similar = element("button", "", t("Find similar"));
  similar.className = "find-similar"; similar.onclick = () => findSimilar(hit);
  buttons.append(open, reveal, similar);
  if (FaceState.isMedia(hit)) {
    const faces = element("button", "find-faces", t("Find faces")); faces.type = "button"; faces.onclick = () => openFaces(hit); buttons.append(faces);
  }
  box.append(buttons);
  return box;
}

function renderFooter() {
  const strong = state.strong.length, weaker = state.weaker.length;
  let summary;
  if (state.error) summary = t("DigUp's helper: {error}", { error: t(state.error) });
  else if (state.phase === "words") {
    summary = state.encoder === "starting" ? t("Matching words; meaning search is warming up…") : t("Matching words…");
  } else if (state.phase === "wordsOnly") summary = t("Words only: meaning search isn't available");
  else if (state.phase === "codeHint") summary = t("Searching your code");
  else summary = state.page ? t("{loaded} of {total} matches loaded", { loaded: strong + weaker, total: state.page.total.toLocaleString(I18n.locale()) })
    : t("{count} results", { count: strong }) + (weaker ? t(" · {count} weaker", { count: weaker }) : "");
  // Results while indexing are partial: say so where they're counted.
  if (state.indexing && !state.error) summary += t(" · indexing is still in progress");
  $summary.textContent = summary;
  $summary.title = state.page ? t("Matches are ranked from the index at query time. Run the query again to include newer changes.") : "";
  $keys.textContent = t("↩ Open   {mod}↩ Show in {manager}", { mod: MOD, manager: fileManager() });
}

function message(title, text) {
  const box = element("div", "message");
  box.append(element("strong", "", title), element("span", "", text));
  return box;
}

// MARK: What a result says

/// The page or moment that matched, as a badge: "p. 3", "0:06", "♪ 0:25" (a video's sound), "L12–40" (code).
function placeOf(hit) {
  if (hit.loc == null) return null;
  switch (hit.segment) {
    case "page":
    case "page_image": return t("p. {page}", { page: Math.trunc(hit.loc) });
    case "frame": return clock(hit.loc);
    case "audio": return hit.kind === "video" ? `♪ ${clock(hit.loc)}` : clock(hit.loc);
    case "lines": {
      const first = Math.trunc(hit.loc), last = Math.trunc(hit.loc_end ?? hit.loc);
      return first === last ? `L${first}` : `L${first}–${last}`;
    }
    case "cells": return span(hit);
    default: return null;
  }
}

function span(hit) {
  if (hit.loc == null) return null;
  const first = Math.trunc(hit.loc), last = Math.trunc(hit.loc_end ?? hit.loc);
  return t(hit.segment === "cells" ? (first === last ? "cell {first}" : "cells {first}–{last}")
    : (first === last ? "line {first}" : "lines {first}–{last}"), { first, last });
}

/// Why it's here, in a few words: t("Matches the picture"), "Matches the frame at 0:06".
function reasonOf(hit) {
  if (state.related && Number.isFinite(hit.cosine)) return t("Similarity {value} · indexed content", { value: hit.cosine.toFixed(3) });
  const meaning = (hit.z ?? 0) >= 2, words = hit.keyword_rank != null;
  if (!meaning) return words ? t("Has your words") : t("Matches its name");
  const at = hit.loc != null ? clock(hit.loc) : "";
  const page = hit.loc != null ? t("page {page}", { page: Math.trunc(hit.loc) }) : t("a page");
  switch (hit.segment) {
    case "image": return hit.kind === "screenshot" ? t("Matches what's on screen") : t("Matches the picture");
    case "ocr": return t("Matches the text in it");
    case "frame": return t("Matches the frame at {at}", { at });
    case "audio": return hit.kind === "video" ? t("Matches the sound at {at}", { at }) : t("Matches what's heard at {at}", { at });
    case "page": return t("Matches the text on {page}", { page });
    case "page_image": return t("Matches {page}", { page });
    case "chunk": return t("Matches its text");
    case "lines":
    case "cells": return t("Matches {span}", { span: span(hit) ?? t("the code") });
    default: return t("Matches its name");
  }
}

/// "Screenshot · Oct 7, 2026 · 1440 × 900 · 62 KB", "PDF · … · 463 pages, 120 read so far · 23 MB"
function details(hit) {
  const info = hit.info || {};
  const parts = [t(KIND_TITLE[hit.kind] || "File"), dateOf(hit.modified)];
  if (info.width && info.height) parts.push(`${info.width} × ${info.height}`);
  const readTo = info.read_to != null ? Number(info.read_to) : null;
  if (info.pages) {
    const pages = Number(info.pages);
    parts.push(t("{count} pages", { count: pages.toLocaleString(I18n.locale()) }) + (readTo != null ? t(", {count} read so far", { count: readTo }) : ""));
  } else if (readTo != null) parts.push(t("partly read so far"));
  if (info.lines) parts.push(t("{count} lines", { count: Number(info.lines).toLocaleString(I18n.locale()) }));
  if (info.duration) parts.push(clock(Number(info.duration)));
  if (hit.size > 0) parts.push(bytes(hit.size));
  return parts.join(" · ");
}

function nameOf(path) {
  return path.split(/[\\/]/).pop();
}

function extensionOf(path) {
  const name = nameOf(path);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
}

/// Where the file is: "~/Downloads/Screenshots"; code says where it is in its repo: "billing/payments".
function folderOf(hit) {
  const folder = hit.path.slice(0, Math.max(0, hit.path.search(/[\\/][^\\/]*$/)));
  const repo = hit.info?.repo;
  if (hit.kind === "code" && repo && hit.path.startsWith(repo + "/")) {
    return folder.slice(repo.slice(0, repo.search(/[\\/][^\\/]*$/)).length + 1);
  }
  const shown = state.home && folder.startsWith(state.home) ? "~" + folder.slice(state.home.length) : folder;
  return isWindows ? shown.replaceAll("/", "\\") : shown;
}

function clock(seconds) {
  const total = Math.trunc(seconds);
  const two = (n) => String(n).padStart(2, "0");
  return total >= 3600 ? `${Math.trunc(total / 3600)}:${two(Math.trunc(total / 60) % 60)}:${two(total % 60)}`
                       : `${Math.trunc(total / 60)}:${two(total % 60)}`;
}

function dateOf(seconds) {
  return new Date(seconds * 1000).toLocaleDateString(I18n.locale(), { year: "numeric", month: "short", day: "numeric" });
}

/// Sizes the way file managers count them (1 KB = 1,000 bytes): "62 KB", "2.1 MB".
function bytes(count) {
  if (count < 1000) return t("{count} bytes", { count });
  const units = ["KB", "MB", "GB", "TB"];
  let value = count / 1000, unit = 0;
  while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit += 1; }
  return `${value >= 10 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

/// An excerpt with the words keyword search found (marked « ») in bold.
function marked(excerpt) {
  return escaped(excerpt).replace(/«([^»]*)»/g, "<b>$1</b>");
}

/// A passage with the query's words marked where they start a word.
function highlighted(text, query) {
  const words = [...new Set(query.toLowerCase().split(/[^\p{L}\p{N}_]+/u).filter((word) => word.length > 1))];
  let html = escaped(text);
  if (!words.length) return html;
  const pattern = new RegExp(`(?<![\\p{L}\\p{N}])(${words.map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})`, "giu");
  return html.replace(pattern, "<mark>$1</mark>");
}

function escaped(text) {
  return text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function kindIcon(kind) {
  const icon = element("div", "thumb icon");
  icon.innerHTML = ICONS[kind] || ICONS.doc;
  return icon;
}

/// The helper's JPEG of a page, a frame or a picture, asked for once per file and place.
const renders = new Map();
async function graphThumbnail(hit) {
  const kind = ["image", "screenshot"].includes(hit.kind) ? "image" : hit.kind;
  const loc = kind === "pdf" ? (hit.segment === "page" || hit.segment === "page_image" ? hit.loc : 1) : kind === "video" ? hit.loc ?? .5 : null;
  const path = await rendered(hit.path, kind, loc, 80);
  if (!path) return null;
  return { path, url: fileURL(path) };
}

function rendered(path, kind, loc, pixels, version = null) {
  const key = JSON.stringify([path, kind, loc, pixels, version?.modified, version?.size]);
  if (!renders.has(key)) {
    renders.set(key, ask({ op: "render", path, kind, loc, pixels,
      ...(Number.isFinite(version?.modified) && Number.isFinite(version?.size) ? { expected_modified: version.modified, expected_size: version.size } : {}) }).then((reply) => {
      if (!reply.image) throw new Error(reply.error || "Preview unavailable"); return reply.image;
    }).finally(() => { renders.delete(key); }));
    if (renders.size > 600) renders.delete(renders.keys().next().value);
  }
  return renders.get(key);
}

const ICONS = {
  chevron: '<svg class="chevron" viewBox="0 0 16 16" width="12" height="12"><path d="M6 3.5 L10.5 8 L6 12.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  play: '<svg viewBox="0 0 20 20"><path d="M5 3 L17 10 L5 17 Z"/></svg>',
  found: '<svg viewBox="0 0 24 24"><circle cx="10" cy="10" r="6.5"/><path d="M15 15 L20.5 20.5 M10 7 V13 M7 10 H13"/></svg>',
  doc: '<svg viewBox="0 0 24 24"><path d="M6 3 H14 L19 8 V21 H6 Z M14 3 V8 H19 M9 12 H16 M9 15 H16 M9 18 H13"/></svg>',
  pdf: '<svg viewBox="0 0 24 24"><path d="M6 3 H14 L19 8 V21 H6 Z M14 3 V8 H19 M9 13 H16 M9 16 H14"/></svg>',
  code: '<svg viewBox="0 0 24 24"><path d="M9 7 L4 12 L9 17 M15 7 L20 12 L15 17"/></svg>',
  audio: '<svg viewBox="0 0 24 24"><path d="M3 12 H5 M7 8 V16 M10 5 V19 M13 9 V15 M16 6 V18 M19 10 V14 M21 12 H22"/></svg>',
  video: '<svg viewBox="0 0 24 24"><path d="M4 6 H15 V18 H4 Z M15 10 L20 7 V17 L15 14"/></svg>',
  image: '<svg viewBox="0 0 24 24"><path d="M4 5 H20 V19 H4 Z M4 16 L9 11 L13 15 L16 12 L20 16"/></svg>',
};
ICONS.screenshot = ICONS.image;

// MARK: Keys and events

$query.addEventListener("input", queryChanged);
$("load-more").addEventListener("click", () => state.page?.expired ? queryChanged() : loadMore());
$("stats-toggle").addEventListener("click", () => {
  if (people.visible) people.close();
  if (faceSearch.visible) faceSearch.close(false);
  if (graph.visible) graph.close();
  state.statsOpen = !state.statsOpen;
  render();
  if (state.statsOpen) refreshStats();
});
$("graph-toggle").addEventListener("click", () => graph.visible ? graph.close() : graph.show(selectedHit(), state.isCode));
$("faces-toggle").addEventListener("click", () => faceSearch.visible ? faceSearch.close() : openFaces(graph.visible ? graph.model.nodes.get(graph.selected) : selectedHit()));
$("people-toggle").addEventListener("click", () => { if (people.visible) people.close(); else people.openTask = people.open(); });
$("graph-reveal").textContent = t("Show in {manager}", { manager: fileManager() });
$("similar-back").onclick = backFromSimilar;
tauri.event.listen("search-scope-changed", () => { if (people.visible) people.close(); people.people = []; people.page.open(null, "assigned"); if (faceSearch.visible) faceSearch.close(false); faceSearch.file = null; faceSearch.selection.clear(); people.faceSelected(); if (graph.visible) graph.close(); if (state.related) queryChanged(); });
$("stats-refresh").addEventListener("click", refreshStats);
setInterval(() => { if (state.statsOpen && !document.hidden && !$("stats-refresh").disabled) refreshStats(); }, 10000);

document.addEventListener("keydown", (event) => {
  if (event.isComposing) return; // an input method is composing: its keys
  if (people.visible && event.key === "Escape") { event.preventDefault(); if (!$("person-rename").hidden) $("person-rename-cancel").click(); else people.close(); return; }
  if (people.visible && event.target.closest?.("#people-view")) return;
  if (faceSearch.visible && event.key === "Escape") { event.preventDefault(); faceSearch.close(); return; }
  if (faceSearch.visible && event.target.closest?.("#faces-view")) return;
  if (graph.visible && event.key === "Escape") { event.preventDefault(); graph.close(); return; }
  if (graph.visible && event.target.closest?.("#graph-view")) return;
  if (event.target.closest?.("button, select")) return; // native Tab/Space/Enter behavior for page and overview controls
  const modifier = isMac ? event.metaKey : event.ctrlKey;
  switch (event.key) {
    case "Escape":
      event.preventDefault();
      invoke("hide_panel").catch(() => {});
      break;
    case "ArrowDown":
    case "ArrowUp":
      if (event.altKey || event.shiftKey || modifier) return;
      event.preventDefault();
      move(event.key === "ArrowDown" ? 1 : -1);
      break;
    case "Enter":
      event.preventDefault();
      if (modifier) revealSelected();
      else if (state.selection === WEAKER) toggleWeaker();
      else openSelected();
      break;
  }
});

tauri.event.listen("panel-shown", () => {
  // Like Spotlight: the last query, selected.
  $query.focus();
  $query.select();
  ask({ op: "prewarm" }).catch(() => {});
  refreshIndexStatus();
  faceSearch.status();
  if (state.statsOpen) refreshStats();
});

tauri.event.listen("helper", ({ payload }) => {
  const { from, event } = payload;
  if (from === "search" && event.event === "encoder") {
    state.encoder = event.state;
    if (state.phase !== "empty") renderFooter();
  }
});

// Listen before asking for the snapshot. Revisions prevent a slower initial IPC reply
// from replacing a newer event, including when the panel is reopened after completion.
tauri.event.listen("index-status", ({ payload }) => showIndexStatus(payload))
  .then(refreshIndexStatus).catch(indexStatusFailed);

function refreshIndexStatus() {
  return invoke("index_status").then(showIndexStatus).catch(indexStatusFailed);
}

function indexStatusFailed() {
  if (state.indexStatus) return;
  $indexTitle.textContent = t("Index status unavailable");
  $indexDetail.textContent = t("Close and reopen the search panel to check again.");
}

function showIndexStatus(status) {
  if (state.indexStatus && status.revision <= state.indexStatus.revision) return;
  state.indexStatus = status;
  state.indexing = ["starting", "scanning", "indexing", "rest"].includes(status.stage) ? status : null;
  progressHistory.push({ ...status });
  if (progressHistory.length > 64) progressHistory.shift();
  if (progressQueued) return;
  progressQueued = true;
  queueMicrotask(() => {
    progressQueued = false;
    renderIndexStatus();
    if (state.phase !== "empty") renderFooter();
  });
}

function renderIndexStatus() {
  const s = state.indexStatus;
  if (!s) return;
  const titles = {
    starting: t("Starting indexing…"), scanning: s.code ? t("Scanning code folders…") : t("Scanning folders…"),
    indexing: s.code ? t("Indexing source code") : t("Indexing files"), rest: t("Reading the rest of long files"),
    idle: s.failed || s.unavailable || s.message ? t("Indexing finished with issues") : t("Indexing complete"),
    paused: t("Indexing paused"), waiting: t("Waiting for the model"), error: t("Indexing needs attention"),
    stopped: t("Indexing stopped"), "no-folders": t("No folders selected"),
  };
  const details = {
    starting: t("Preparing the local index. Files already indexed remain searchable."),
    scanning: t("Checking for new, changed and deleted files. Earlier results stay searchable."),
    indexing: t("Files become searchable as they are indexed. Counts are for this pass."),
    rest: t("Long files are read in parts. Counts are for the remaining parts in this pass."),
    idle: t("Watching the selected folders for changes."),
    paused: t("Choose Index Now / Resume in the tray to continue. Your index is saved."),
    waiting: t("Indexing starts when the local model is ready."),
    error: t("Check folder access and the processing device, then resume from the tray."),
    stopped: t("Choose Index Now / Resume in the tray to try again."),
    "no-folders": t("Choose Folders… in the tray to start indexing."),
  };
  const number = (n) => n.toLocaleString(I18n.locale());
  const counted = Number.isFinite(s.done) && Number.isFinite(s.total);
  const overall = [s.searchable != null ? t("{count} files searchable", { count: number(s.searchable) }) : "",
    s.pending != null ? t("{count} remaining", { count: number(s.pending) }) : ""].filter(Boolean).join(" · ");
  const raw = Math.min(s.failed || 0, s.unsupported_raw || 0);
  const failedFiles = Math.max(0, (s.failed || 0) - raw);
  $indexStatus.dataset.stage = s.stage;
  $indexTitle.textContent = titles[s.stage] || t("Indexing");
  $indexCount.textContent = counted ? t("{done} of {total} {unit} processed this pass", { done: number(s.done), total: number(s.total), unit: t(s.unit) }) : overall;
  const problems = [failedFiles ? t("{count} files couldn't be indexed", { count: number(failedFiles) }) : "",
    raw ? t("{count} RAW files not supported", { count: number(raw) }) : "",
    s.skipped ? t("{count} files skipped", { count: number(s.skipped) }) : "",
    s.unavailable ? t("{count} folders unavailable", { count: number(s.unavailable) }) : ""].filter(Boolean).join(" · ");
  $indexDetail.textContent = [problems, s.message ? t(s.message) : "", counted ? overall : "", s.message ? "" : details[s.stage]]
    .filter(Boolean).join(" · ");
  $indexDetail.title = $indexDetail.textContent;
  $indexProgress.hidden = !counted || s.total === 0 || s.done > s.total || !["indexing", "rest"].includes(s.stage);
  if (!$indexProgress.hidden) {
    $indexProgress.max = s.total;
    $indexProgress.value = s.done;
    $indexProgress.setAttribute("aria-valuetext", $indexCount.textContent);
  }
}

document.addEventListener("ui-language-changed", () => {
  $("graph-reveal").textContent = t("Show in {manager}", { manager: fileManager() });
  renderIndexStatus(); render(); if (graph.visible) graph.render();
  if (state.statsOpen) refreshStats();
});
render();
faceSearch.status();

tauri.path.homeDir().then((home) => { state.home = home.replace(/[\\/]$/, ""); }).catch(() => {});

// Debug runs (--debug-query): type the query in, and once the meaning results and their pictures are in, report
// what the panel shows.
function debugSearch(query) {
  if (!query) return;
  debugPending = true;
  $query.value = query;
  queryChanged();
}
Promise.all([invoke("debug_search_options"), invoke("debug_query"), I18n.ready]).then(([options, query]) => {
  debugOptions = options;
  debugSearch(query);
});
tauri.event.listen("debug-query", ({ payload }) => debugSearch(payload));   // after setup's first index

// Isolated, native face smoke. Every observation comes from the real worker/index.
async function exerciseFaceSearchUi() {
  const report = featureReport.faces = {};
  const wait = async (predicate, milliseconds = 120000) => {
    const deadline = Date.now() + milliseconds;
    while (!predicate()) {
      if (Date.now() >= deadline) throw new Error("Face UI smoke timed out");
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  };
  const photo = [...state.strong, ...state.weaker].find((hit) => ["image", "screenshot"].includes(hit.kind) && /crew/i.test(hit.path))
    || [...state.strong, ...state.weaker].find((hit) => ["image", "screenshot"].includes(hit.kind));
  if (!photo) throw new Error("Face smoke has no real indexed photograph");
  state.selection = photo.path; state.navigated = true; render();
  const action = $preview.querySelector(".find-faces"); if (!action) throw new Error("Face action missing from media preview");
  action.click(); await wait(() => faceSearch.visible && !!faceSearch.index && !!faceSearch.fileReply && !faceSearch.fileBusy && faceSearch.deviceLoaded);
  if (!faceSearch.index.worker_available) throw new Error("Packaged face worker unavailable");
  $("face-device").value = "auto"; $("face-device").dispatchEvent(new Event("change", { bubbles: true }));
  await wait(() => !faceSearch.deviceSaving);
  if (faceSearch.deviceSaveError) throw new Error("Face device preference could not save");
  $("face-start").click(); await wait(() => !faceSearch.actionBusy);
  if (faceSearch.statusError) throw new Error(faceSearch.statusError);
  await wait(() => ["completed", "error"].includes(faceSearch.index?.state), 900000);
  if (faceSearch.index.state === "error") throw new Error(faceSearch.index.error || "Face indexing failed");
  $("face-refresh").click(); await faceSearch.refreshTask;
  await wait(() => !faceSearch.fileBusy && !!faceSearch.fileReply?.indexed && faceSearch.fileFaces.length > 0);
  await wait(() => faceSearch.debug().sourceLoaded && $("face-source-image").querySelectorAll(".face-box").length > 0);
  // A background-image URL being assigned is not proof that its pixels have
  // decoded. Capture the finished real selector, including every rendered crop.
  // A previously assigned label can make the source controls taller. Exercise real scrolling to the
  // deferred face choices rather than waiting for offscreen thumbnails to load themselves.
  $("face-choices").scrollIntoView({ block: "nearest" });
  await wait(() => {
    const crops = [...$("face-choices").querySelectorAll(".face-crop")];
    return crops.length > 0 && crops.every((crop) => crop.dataset.loaded === "true" && getComputedStyle(crop).backgroundImage !== "none");
  });
  await Promise.all(faceSearch.fileFaces.map(async (face) => {
    const image = new Image(); image.src = await faceSearch.imageFor({ ...faceSearch.file, ...face }, 360); await image.decode();
  }));
  document.querySelector(".face-source").scrollTop = 0;
  await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  report.index = faceSearch.index; report.progressHistory = faceSearch.statusHistory; report.source = photo.path;
  report.faceChoices = faceSearch.fileFaces.length; report.boxes = $("face-source-image").querySelectorAll(".face-box").length;
  await invoke("debug_capture", { label: "faces-select" });
  const first = faceSearch.fileFaces[0];
  $("face-source-image").querySelector(".face-box")?.click();
  await wait(() => !!faceSearch.selection.seed && !faceSearch.searchBusy);
  if (faceSearch.searchError) throw new Error(faceSearch.searchError);
  if (faceSearch.fileFaces.length > 1) {
    const other = faceSearch.fileFaces[1];
    const choose = (id) => [...$("face-choices").querySelectorAll("button")].find((button) => button.dataset.faceId === String(id))?.click();
    choose(other.id); choose(first.id); await wait(() => !faceSearch.searchBusy);
    report.selectionRacePreserved = FaceState.faceKey(faceSearch.selection.seed) === FaceState.faceKey(first);
  }
  report.selectedFace = faceSearch.selection.seed; report.firstPage = faceSearch.selection.hits.length;
  while (faceSearch.selection.hasMore && faceSearch.selection.hits.length < 200) {
    $("face-search-more").click(); await wait(() => !faceSearch.searchBusy);
    if (faceSearch.searchError) throw new Error(faceSearch.searchError);
  }
  if (!faceSearch.selection.hits.length) throw new Error("Real SFace query returned no matching observations");
  await wait(() => faceSearch.debug().loadedCrops > 1);
  report.matches = faceSearch.selection.hits; report.total = faceSearch.selection.total;
  await invoke("debug_capture", { label: "faces-matches" });
  const video = faceSearch.selection.hits.find((hit) => hit.kind === "video" && Number.isFinite(hit.loc) && hit.loc > 0);
  if (!video) throw new Error("Real face query has no matching video timestamp");
  [...$("face-results-list").querySelectorAll("button")].find((button) => button.dataset.faceId === FaceState.faceKey(video))?.click();
  const moment = $("face-match-preview").querySelector(".picture"); if (!moment) throw new Error("Video face preview missing");
  moment.click();
  const videoState = () => {
    const player = moment.querySelector("video");
    return { path: video.path, loc: video.loc, currentTime: player?.currentTime ?? null, source: player?.getAttribute("src") ?? null,
      readyState: player?.readyState ?? null, networkState: player?.networkState ?? null,
      mediaState: moment.dataset.mediaState, previewState: moment.dataset.previewState,
      errorCode: player?.error?.code ?? moment.dataset.mediaErrorCode ?? null,
      errorMessage: player?.error?.message || moment.dataset.mediaError || null,
      playerPresent: !!player, fallbackVisible: !!moment.querySelector(".preview-unavailable") };
  };
  try {
    await wait(() => { const player = moment.querySelector("video"); return player?.readyState >= 1 || !!player?.error || moment.dataset.mediaState === "error" || !!moment.querySelector(".preview-unavailable") || !player; }, 30000);
  } catch (error) {
    report.video = videoState(); await invoke("debug_capture", { label: "faces-video" }); throw error;
  }
  report.video = videoState();
  const player = moment.querySelector("video");
  if (!player || player.error || moment.dataset.mediaState === "error") {
    await invoke("debug_capture", { label: "faces-video" });
    throw new Error(`Native video face preview failed (MediaError ${report.video.errorCode ?? "unknown"}: ${report.video.errorMessage || "player unavailable"})`);
  }
  player.pause(); player.currentTime = video.loc;
  await wait(() => Math.abs(player.currentTime - video.loc) < .25 && !player.seeking);
  report.video = { path: video.path, loc: video.loc, currentTime: player.currentTime, source: player.getAttribute("src"), readyState: player.readyState };
  await invoke("debug_capture", { label: "faces-video" });
  $("face-show-graph").click(); await wait(() => graph.visible && !graph.loading);
  report.graph = { faceMode: graph.faceMode, source: graph.model.source, files: graph.model.nodes.size,
    edges: [...graph.model.edges.values()].map((edge) => ({ matchTypes: edge.matchTypes, evidence: edge.evidence })) };
  if (!report.graph.edges.some((edge) => edge.matchTypes.includes("face"))) throw new Error("Face results did not create real face graph evidence");
}

// Native screenshots require decoded pixels in the actual viewport. Offscreen album rows intentionally do
// not decode images: the scroll/pagination smoke below exercises those by bringing them into view.
async function waitForVisiblePeopleCrops(wait) {
  await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  const root = $("person-faces").getBoundingClientRect();
  const visible = [...$("person-faces").querySelectorAll(".face-crop")].filter((crop) => {
    const box = crop.getBoundingClientRect(); return box.bottom > root.top && box.top < root.bottom && box.height > 0;
  });
  await wait(() => visible.every((crop) => crop.dataset.loaded === "true"));
  await Promise.all(visible.map(async (crop) => { const image = new Image(); image.src = crop.dataset.imageUrl; await image.decode(); }));
  return visible.length;
}

// Drives real filesystem/watch/face publication. The external smoke copies public
// fixtures only after the native capture markers; this path never calls face_start.
async function exerciseAutomaticFacesUi() {
  const report = featureReport.autoFaces = { manualFaceStarts: 0 };
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const wait = async (action, timeout = 180000) => {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      const value = await action(); if (value) return value;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error("Automatic face smoke timed out");
  };
  const poll = async () => { await faceSearch.background.refresh(); return faceSearch.autoDebug(); };
  const ready = async () => { const value = await poll(); return value.summary?.state === "ready" ? value : null; };
  const toggle = async (enabled) => {
    const box = $("face-auto-enabled"); check(!box.disabled, "Automatic face control unavailable");
    if (box.checked !== enabled) { box.click(); await faceSearch.background.actionTask; }
    await wait(async () => (await poll()).index?.auto_enabled === enabled);
  };
  const photoName = "AUTO FACE742 Новое фото.jpg", pausedName = "AUTO FACE742 Пауза.jpg", offlineName = "AUTO FACE742 После перезапуска.jpg";
  const videoName = "AUTO FACE742 Новое видео.mp4";
  await people.refreshDirectory();
  const person = people.people.find((entry) => entry.name === "Человек FACE742");
  check(person, "People baseline label missing");
  const page = async (mode) => {
    await people.selectPerson(person.id, mode);
    while (people.page.hasMore) await people.loadPage(true);
    check(!people.pageError, people.pageError || "People page failed"); return people.page.hits.slice();
  };
  const capture = async (label) => {
    if (people.visible) {
      await waitForVisiblePeopleCrops(wait);
    }
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    await invoke("debug_capture", { label });
  };
  const indexedFile = async (path) => {
    const reply = await ask({ op: "face_file", path });
    return reply.ok !== false && reply.indexed && reply.faces?.length > 0 ? reply : null;
  };
  const ordinaryFile = async (path) => {
    const reply = await ask({ op: "search_page", q: nameOf(path), meaning: false, limit: 200 });
    return reply.ok !== false && reply.hits?.some((hit) => hit.path === path);
  };
  const firstFile = [...state.strong, ...state.weaker].find((hit) => /FACE742/.test(hit.path));
  check(firstFile, "Automatic smoke has no real fixture directory");
  const prefix = firstFile.path.slice(0, Math.max(firstFile.path.lastIndexOf("/"), firstFile.path.lastIndexOf("\\")) + 1);
  const paths = { photo: prefix + photoName, video: prefix + videoName, paused: prefix + pausedName, offline: prefix + offlineName };
  const assigned = await ask({ op: "person_faces", person_id: person.id, mode: "assigned", limit: 200 });
  check(assigned.ok !== false, assigned.error || "Assigned baseline unavailable");
  const restarted = assigned.hits?.some((hit) => nameOf(hit.path) === photoName);
  report.phase = restarted ? "restart" : "live";
  if (!restarted) {
    check(!people.visible && !faceSearch.visible, "Automatic processing must start with the face workspaces closed");
    const initial = await wait(ready); check(initial.index.auto_enabled, "Existing face opt-in did not enable automatic indexing");
    report.initialSummary = initial.summary; report.workspacesClosedAtStart = true;
    await capture("auto-waiting"); // PowerShell now adds a real photo and H.264 video.
    let progressCaptured = false;
    await wait(async () => {
      const value = await poll();
      if (!progressCaptured && value.index?.active && value.index.total_frames > 0) {
        report.progress = { ...value.index }; report.startedWithoutWorkspace = !people.visible && !faceSearch.visible;
        // Capture immediately while the real job is active. Opening the People
        // directory and decoding its historical crops can outlast a short video.
        report.progressCapture = { active: value.index.active, message: $("face-auto-message").textContent,
          progressVisible: !$("face-auto-progress").hidden };
        await capture("auto-progress"); progressCaptured = true;
      }
      return progressCaptured && !value.index?.active && await indexedFile(paths.photo) && await indexedFile(paths.video);
    }, 900000);
    report.realWatcherIndexedPhoto = !!await ordinaryFile(paths.photo); report.realWatcherIndexedVideo = !!await ordinaryFile(paths.video);
    check(report.realWatcherIndexedPhoto && report.realWatcherIndexedVideo, "New files did not enter the ordinary index through the real watcher");
    if (!people.visible) await people.open();
    const suggestions = await page("suggestions"), newRows = suggestions.filter((hit) => [photoName, videoName].includes(nameOf(hit.path)));
    check(newRows.some((hit) => nameOf(hit.path) === photoName) && newRows.some((hit) => nameOf(hit.path) === videoName && hit.loc > 0), "Automatic proposals lack a real photo/video timestamp");
    report.newSuggestions = newRows.map((hit) => ({ path: hit.path, face_id: hit.face_id, loc: hit.loc }));
    const before = await wait(ready); report.pendingBefore = before.summary.total;
    check(before.summary.total === suggestions.length, "Pending counter differs from the actual proposal page");
    await capture("auto-suggestions");
    const choose = (hit) => {
      const key = people.faceRowKey(hit), box = [...$("person-faces").querySelectorAll("input")].find((input) => input.dataset.faceKey === key);
      check(box, "Automatic proposal checkbox missing"); box.click();
    };
    choose(newRows.find((hit) => nameOf(hit.path) === photoName));
    $("person-assign").click(); await people.mutationTask; check(!people.mutationError, people.mutationError || "Accept failed");
    report.pendingAfterAccept = (await wait(async () => { const next = await ready(); return next && next.summary.total === report.pendingBefore - 1 ? next : null; })).summary.total;
    const remaining = people.page.hits.find((hit) => nameOf(hit.path) === videoName); choose(remaining);
    $("person-reject").click(); await people.mutationTask; check(!people.mutationError, people.mutationError || "Reject failed");
    report.pendingAfterReject = (await wait(async () => { const next = await ready(); return next && next.summary.total === report.pendingBefore - 2 ? next : null; })).summary.total;
    await toggle(false); await capture("auto-paused"); // Smoke copies another real photo while paused.
    await wait(() => ordinaryFile(paths.paused));
    await new Promise((resolve) => setTimeout(resolve, 3000));
    check(!await indexedFile(paths.paused), "Paused automatic indexing processed a new file"); report.pauseRespected = true;
    await toggle(true);
    await wait(() => indexedFile(paths.paused), 900000);
    const resumed = await wait(async () => { const next = await ready(); return next && next.summary.total === report.pendingAfterReject + 1 ? next : null; });
    report.pendingAfterResume = resumed.summary.total; report.resumedWithoutFaceStart = true;
    await page("suggestions"); await capture("auto-resumed");
    await toggle(false); report.pausedForRestart = true;
  } else {
    const initial = await wait(ready); check(!initial.index.auto_enabled && !initial.index.active, "Automatic pause did not persist across restart");
    report.pausePersisted = true;
    await wait(() => ordinaryFile(paths.offline));
    check(!await indexedFile(paths.offline), "Restart bypassed the saved automatic pause");
    const accepted = assigned.hits.some((hit) => nameOf(hit.path) === photoName);
    await people.open(); const rejected = await page("rejected");
    check(accepted && rejected.some((hit) => nameOf(hit.path) === videoName), "Automatic proposal decisions were lost on restart"); report.decisionsPersisted = true;
    await toggle(true); await wait(() => indexedFile(paths.offline), 900000);
    const current = await wait(ready), suggestions = await page("suggestions");
    report.pendingAfterRestart = current.summary.total;
    check(current.summary.total === suggestions.length && suggestions.some((hit) => nameOf(hit.path) === offlineName), "Restart did not publish new suggestions");
    const revision = current.summary.index_revision;
    await new Promise((resolve) => setTimeout(resolve, 3000));
    const stable = await wait(ready); check(stable.summary.total === current.summary.total && stable.summary.index_revision === revision, "Idle auto passes created duplicates");
    report.idleStable = true; await capture("auto-suggestions");
  }
  report.status = faceSearch.autoDebug(); report.passed = true;
}

async function exercisePeopleUi() {
  const report = featureReport.people = {};
  const label = "Человек FACE742", renamed = "Наблюдатель FACE742";
  const wait = async (predicate) => {
    const deadline = Date.now() + 60000;
    while (!predicate()) { if (Date.now() >= deadline) throw new Error("People UI smoke timed out"); await new Promise((resolve) => setTimeout(resolve, 30)); }
  };
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const mutation = async (id) => {
    const button = $(id); check(!button.disabled && !button.hidden, `${id} action is unavailable`); button.click(); await people.mutationTask;
    if (people.mutationError) throw new Error(people.mutationError); return people.lastMutation;
  };
  const tab = async (mode) => { document.querySelector(`[data-person-mode="${mode}"]`).click(); await people.pageTask; if (people.pageError) throw new Error(people.pageError); };
  const allPages = async () => {
    while (people.page.hasMore) { $("person-more").click(); await people.pageTask; if (people.pageError) throw new Error(people.pageError); }
  };
  const selectObservation = (hit) => {
    const key = people.faceRowKey(hit), box = [...$("person-faces").querySelectorAll("input")].find((input) => input.dataset.faceKey === key);
    check(!!box, "Person observation checkbox missing"); if (!box.checked) box.click();
  };
  const capture = async (name) => {
    const hits = people.page.hits;
    if (hits.length && people.page.mode !== "stale") {
      await waitForVisiblePeopleCrops(wait);
    }
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    await invoke("debug_capture", { label: name });
  };
  await people.refreshDirectory();
  let person = people.people.find((item) => item.name === label);
  if (!person) {
    report.phase = "first";
    const seed = faceSearch.selection.seed; check(!!seed, "Faces smoke must supply the chosen source face");
    $("faces-toggle").click(); await faceSearch.openTask; await wait(() => faceSearch.visible && !faceSearch.fileBusy && !!faceSearch.fileReply);
    const choice = [...$("face-choices").querySelectorAll("button")].find((button) => button.dataset.faceId === FaceState.faceKey(seed));
    check(!!choice, "Chosen source face missing after graph return"); choice.click(); await wait(() => !faceSearch.searchBusy && faceSearch.selection.hits.length > 0);
    await people.refreshDirectory();
    $("face-person-name").value = label; $("face-person-create").requestSubmit(); await people.createTask;
    if (people.mutationError) throw new Error(people.mutationError);
    person = people.people.find((item) => item.name === label); check(!!person, "Unicode person label was not created");
    $("face-person").value = String(person.id); $("face-person").dispatchEvent(new Event("change", { bubbles: true }));
    await mutation("face-assign-seed");
    report.bulkLoadedBefore = faceSearch.selection.hits.length; report.bulkTotalMatches = faceSearch.selection.total;
    check(report.bulkLoadedBefore < report.bulkTotalMatches, "Bulk smoke must run before every result page is loaded");
    const excluded = faceSearch.selection.hits[0];
    $("face-select-all").click();
    const excludeBox = [...$("face-results-list").querySelectorAll("input")].find((input) => input.dataset.faceId === FaceState.faceKey(excluded));
    check(excludeBox?.checked, "All-matches selection did not select loaded observations"); excludeBox.click();
    const all = await mutation("face-assign-matches"); report.bulkChange = all;
    person = people.people.find((item) => PeopleState.samePerson(item.id, person.id));
    report.bulkAssignedBeyondLoaded = person.assigned_count > report.bulkLoadedBefore; check(report.bulkAssignedBeyondLoaded, "Bulk assignment was restricted to loaded rows");
    $("face-clear-selected").click();
    const rejectBox = [...$("face-results-list").querySelectorAll("input")].find((input) => input.dataset.faceId === FaceState.faceKey(excluded)); rejectBox.click();
    await mutation("face-reject-matches");
    $("face-label-undo").querySelector("button").click(); await people.mutationTask;
    report.exclusionUndo = people.people.find((item) => PeopleState.samePerson(item.id, person.id)).rejected_count === 0;
    check(report.exclusionUndo, "Exclusion undo did not restore the prior state");
    const again = [...$("face-results-list").querySelectorAll("input")].find((input) => input.dataset.faceId === FaceState.faceKey(excluded)); if (!again.checked) again.click();
    await mutation("face-reject-matches"); report.excludedFace = FaceState.faceKey(excluded);
    $("people-toggle").click(); await people.openTask;
    await people.selectPerson(person.id, "assigned"); await allPages();
    const before = people.page.total, target = people.page.hits.find((hit) => PeopleState.idOf(hit) !== FaceState.faceKey(seed)); selectObservation(target);
    await mutation("person-remove"); check(people.page.total === before - 1, "Removing one label changed an unexpected number of observations");
    $("people-undo").querySelector("button").click(); await people.mutationTask;
    report.selectiveUndo = people.page.total === before; check(report.selectiveUndo, "Selective label undo failed");
  } else {
    $("people-toggle").click(); await people.openTask; await people.selectPerson(person.id, "assigned"); await allPages();
    const assignedBefore = people.page.hits.slice(); report.assignedBefore = people.page.total;
    await tab("suggestions"); await allPages();
    const candidates = people.page.hits.filter((hit) => /FACE742 Новый файл 0[12]/.test(hit.path));
    if (candidates.length) {
      report.phase = "restart";
      report.suggestionsNotAutoAssigned = !assignedBefore.some((hit) => /FACE742 Новый файл 0[12]/.test(hit.path));
      check(report.suggestionsNotAutoAssigned && candidates.length === 2, "New files were assigned automatically or their proposals are missing");
      report.suggestionCapturedTotal = people.page.total; await capture("people-suggestions"); report.suggestionsCapturedBeforeDecision = true;
      const accepted = candidates.find((hit) => /01/.test(nameOf(hit.path))), rejected = candidates.find((hit) => /02/.test(nameOf(hit.path)));
      selectObservation(accepted); await mutation("person-assign"); report.acceptedNew = accepted.path;
      const reject = people.page.hits.find((hit) => hit.path === rejected.path); check(!!reject, "Unconfirmed suggestion disappeared after accepting another");
      selectObservation(reject); await mutation("person-reject"); report.rejectedNew = rejected.path;
    } else {
      report.phase = "verify";
      report.acceptedNew = assignedBefore.find((hit) => /FACE742 Новый файл 01/.test(hit.path))?.path;
      await tab("rejected"); await allPages(); report.rejectedNew = people.page.hits.find((hit) => /FACE742 Новый файл 02/.test(hit.path))?.path;
      await tab("suggestions"); await allPages();
      report.persistenceVerified = !!report.acceptedNew && !!report.rejectedNew && !people.page.hits.some((hit) => /FACE742 Новый файл 0[12]/.test(hit.path));
      check(report.persistenceVerified, "Confirmed/excluded new observations did not persist correctly");
    }
  }
  report.personId = person.id;
  const albumStarted = performance.now();
  await people.selectPerson(person.id, "assigned");
  const album = report.albumAccess = { firstPageMs: performance.now() - albumStarted, firstPage: people.page.hits.length, total: people.page.total };
  album.visibleDecoded = await waitForVisiblePeopleCrops(wait);
  const list = $("person-faces"), firstRow = list.firstElementChild, firstCrop = firstRow?.querySelector(".face-crop"), preview = $("person-preview").firstElementChild;
  album.initialThumbnailRequests = list.querySelectorAll('.face-crop[data-requested="true"]').length;
  album.offscreenDeferred = album.initialThumbnailRequests < people.page.hits.length;
  check(album.offscreenDeferred && album.visibleDecoded > 0, "Album thumbnails must decode visible media while deferring offscreen files");
  firstRow.querySelector("input").click(); firstRow.querySelector("input").click();
  album.rowRetainedOnCheck = list.firstElementChild === firstRow && firstRow.querySelector(".face-crop") === firstCrop && $("person-preview").firstElementChild === preview;
  check(album.rowRetainedOnCheck, "Selection recreated album rows, thumbnails or the current preview");
  if (people.page.hasMore) {
    list.scrollTop = list.scrollHeight; list.dispatchEvent(new Event("scroll"));
    await wait(() => !people.pageBusy && (people.page.hits.length > album.firstPage || !people.page.hasMore));
    check(!people.pageError, people.pageError || "Automatic album pagination failed");
    album.automaticPageBeyond40 = people.page.hits.length > 40;
    check(album.automaticPageBeyond40, "Scrolling did not load photographs beyond the first 40");
    const last = list.lastElementChild; last.scrollIntoView({ block: "end" });
    await waitForVisiblePeopleCrops(wait);
    album.laterThumbnailDecoded = last.querySelector(".face-crop")?.dataset.loaded === "true";
    check(album.laterThumbnailDecoded, "Newly visible later-page photograph was not decoded");
  }
  await allPages(); album.loaded = people.page.hits.length;
  check(album.loaded === people.page.total, "The complete labelled album was truncated");
  const probe = people.page.hits.find((hit) => hit.kind !== "video");
  const cached = await ask({ op: "render", path: probe.path, kind: "image", pixels: 361, expected_modified: probe.modified, expected_size: probe.size });
  check(!!cached.image && cached.cached === (report.phase !== "first"), "Versioned thumbnail cache did not persist across actual GUI restarts");
  const cacheImage = new Image(); cacheImage.src = fileURL(cached.image); await cacheImage.decode();
  album.cacheProbePath = cached.image; album.cacheProbeReused = cached.cached; album.cacheProbeDecoded = cacheImage.naturalWidth > 0;
  list.scrollTop = 0;
  report.assignedTotal = people.page.total; await capture("people-assigned");
  // The gallery is a distinct file-level view; keep all observation review checks above intact.
  await people.selectPerson(person.id);
  const gallery = report.gallery = { mode: people.page.mode, firstPage: people.page.hits.length, total: people.page.total };
  check(gallery.mode === "gallery" && gallery.firstPage === 40 && gallery.total > 40, "The default person view must page unique labelled files");
  const tile = $("person-faces").querySelector(".people-tile"), tileImage = tile.querySelector("img");
  await wait(() => tileImage.complete && tileImage.naturalWidth > 0);
  const visibleGalleryMedia = () => {
    const bounds = $("person-faces").getBoundingClientRect();
    return [...$("person-faces").querySelectorAll(".people-tile-media")].filter((stage) => {
      const rect = stage.getBoundingClientRect(); return rect.bottom > bounds.top && rect.top < bounds.bottom;
    });
  };
  await wait(() => visibleGalleryMedia().length > 0 && visibleGalleryMedia().every((stage) => stage.dataset.loaded === "true"));
  gallery.visibleDecoded = visibleGalleryMedia().length;
  gallery.offscreenDeferred = $("person-faces").querySelectorAll('[data-requested="true"]').length < gallery.firstPage;
  check(gallery.offscreenDeferred, "Offscreen whole-photo tiles must remain deferred");
  gallery.wholeImage = getComputedStyle(tileImage).objectFit === "contain" && !tile.querySelector(".face-crop");
  check(gallery.wholeImage, "Gallery must show the whole photograph rather than a face crop");
  await invoke("debug_capture", { label: "people-gallery" });
  tile.click();
  await wait(() => { const image = $("person-viewer-media").querySelector("img"); return image?.complete && image.naturalWidth > 0; });
  check($("person-viewer").open && people.viewerIndex === 0, "Clicking a tile must open its full media preview");
  const key = async (value) => { $("person-viewer").dispatchEvent(new KeyboardEvent("keydown", { key: value, bubbles: true })); await people.viewerTask; };
  await key("ArrowLeft"); check(people.viewerIndex === 0, "Previous must stop at the first file");
  await key("ArrowRight"); check(people.viewerIndex === 1, "Right arrow must show the next unique file");
  $("person-viewer-previous").click(); await people.viewerTask;
  check(people.viewerIndex === 0, "Previous button must return to the first file");
  for (let i = 1; i < gallery.firstPage; i++) await key("ArrowRight");
  await key("ArrowRight");
  gallery.arrowLoadedNextPage = people.viewerIndex === 40 && people.page.hits.length > 40;
  check(gallery.arrowLoadedNextPage && !people.pageError, "Arrow navigation must load the next file page at its boundary");
  await allPages();
  gallery.loaded = people.page.hits.length;
  gallery.uniqueFiles = new Set(people.page.hits.map((hit) => hit.path)).size;
  gallery.repeatedVideoFramesGrouped = people.page.hits.some((hit) => hit.kind === "video" && hit.observation_count > 1);
  check(gallery.loaded === gallery.total && gallery.uniqueFiles === gallery.total && gallery.total === people.counts.assigned_files && gallery.repeatedVideoFramesGrouped,
    "The complete gallery must have one tile per file, including videos with multiple labelled frames");
  while (people.viewerIndex < gallery.total - 1) await key("ArrowRight");
  check(people.viewerIndex === gallery.total - 1, "Viewer must reach the final unique file");
  await key("ArrowRight"); check(people.viewerIndex === gallery.total - 1 && $("person-viewer-next").disabled, "Next must stop at the final file");
  await key("Escape");
  gallery.escapeRestoresFocus = !$("person-viewer").open && people.visible && document.activeElement === tile;
  check(gallery.escapeRestoresFocus, "Esc must close only the viewer and return focus to the originating tile");
  tile.click(); await wait(() => { const image = $("person-viewer-media").querySelector("img"); return image?.complete && image.naturalWidth > 0; });
  await invoke("debug_capture", { label: "people-gallery-viewer" });
  people.closeViewer();
  await tab("suggestions"); await allPages(); report.suggestionTotal = people.page.total;
  if (!report.suggestionsCapturedBeforeDecision) { report.suggestionCapturedTotal = people.page.total; await capture("people-suggestions"); }
  $("person-rename-toggle").click(); $("person-name").value = renamed; $("person-rename").requestSubmit(); await people.mutationTask;
  if (people.mutationError) throw new Error(people.mutationError);
  check(people.person()?.name === renamed, "Person rename did not reach the visible UI"); await capture("people-rename");
  $("people-undo").querySelector("button").click(); await people.mutationTask;
  report.renameUndo = people.person()?.name === label; check(report.renameUndo, "Person rename undo failed");
  const final = people.people.find((item) => PeopleState.samePerson(item.id, person.id));
  report.rejectedTotal = final.rejected_count; report.excludedCount = final.rejected_count; report.assignedTotal = final.assigned_count;
  report.passed = true;
}

async function completeDebugSearch() {
  debugPending = false;
  if (debugOptions.loadAll) {
    const deadline = Date.now() + 60000;
    const record = () => debugPages.push({ loaded: state.strong.length + state.weaker.length,
      offset: state.page?.offset, total: state.page?.total, hasMore: state.page?.hasMore,
      largestGroup: Math.max(0, ...state.groups.map((group) => group.rows.length)),
      renderedRows: $list.querySelectorAll(".row").length });
    record();
    while (state.page?.hasMore && !state.pageError && Date.now() < deadline) {
      $("load-more").click(); // same native DOM control the user clicks; no fabricated backend responses
      while (state.loadingMore && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 25));
      record();
    }
    $("stats-toggle").click();
    while ($("stats-refresh").disabled && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 25));
    if (Date.now() >= deadline) state.error = "Pagination smoke timed out";
  }
  if (debugOptions.graph) {
    const deadline = Date.now() + 60000;
    $("graph-toggle").click();
    while (graph.loading && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 25));
    const first = graph.debug();
    if (!$('graph-related-details').open) $('graph-related-details').querySelector('summary').click();
    $("graph-neighbors").querySelector("button")?.click();
    $("graph-expand").click();
    while (graph.loading && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 25));
    graph.debugFirst = first;
    if (Date.now() >= deadline) state.error = "Graph smoke timed out";
  }
  if (debugOptions.features) {
    try { await exerciseUiFeatures(); }
    catch (error) { state.error = String(error.message || error); featureReport.failureGraph = graph.debug(); }
  }
  if (debugOptions.faces) {
    try { await exerciseFaceSearchUi(); }
    catch (error) { state.error = String(error.message || error); featureReport.faces = { ...featureReport.faces, error: state.error, failure: faceSearch.debug() }; }
  }
  if (debugOptions.people) {
    try { await exercisePeopleUi(); }
    catch (error) { state.error = String(error.message || error); featureReport.people = { ...featureReport.people, error: state.error, failure: people.debug() }; }
  }
  if (debugOptions.autoFaces) {
    try { await exerciseAutomaticFacesUi(); }
    catch (error) { state.error = String(error.message || error); featureReport.autoFaces = { ...featureReport.autoFaces, error: state.error, failure: faceSearch.autoDebug() }; }
  }
  report();
}

function report() {
  debugPending = false;
  setTimeout(() => {
    const big = $preview.querySelector("img, video, audio, .passage");
    const thumbs = [...$list.querySelectorAll("img.thumb")];
    invoke("debug_report", {
      report: {
        query: $query.value,
        features: featureReport,
        language: I18n.language,
        graph: debugOptions.graph ? { ...graph.debug(), first: graph.debugFirst } : null,
        appearance: { panelRadius: getComputedStyle(document.querySelector(".panel")).borderRadius,
          bodyBackground: getComputedStyle(document.body).backgroundColor },
        phase: state.phase,
        error: state.error,
        groups: state.groups.map((group) => ({ title: group.title, rows: group.rows.map((hit) => nameOf(hit.path)) })),
        weaker: state.weaker.length,
        selected: state.selection && nameOf(state.selection),
        preview: big && {
          tag: big.tagName.toLowerCase(),
          loaded: big.tagName === "IMG" ? big.complete && big.naturalWidth > 0 : null,
          size: big.tagName === "IMG" ? `${big.naturalWidth}x${big.naturalHeight}` : null,
          text: big.classList.contains("passage") ? big.textContent.slice(0, 80) : null,
        },
        thumbnails: `${thumbs.filter((image) => image.complete && image.naturalWidth > 0).length} of ${thumbs.length} drawn`,
        facts: [...$preview.querySelectorAll(".facts .title, .facts .line, .reason span")].map((node) => node.textContent),
        footer: [$summary.textContent, $keys.textContent],
        pagination: { ...state.page, loaded: state.strong.length + state.weaker.length, error: state.pageError,
          paths: [...state.strong, ...state.weaker].map((hit) => nameOf(hit.path)), pages: debugPages,
          buttonVisible: !$("more-controls").hidden },
        overview: { visible: !$("index-overview").hidden, data: state.stats,
          message: $("stats-message").textContent, totals: $("stats-totals").textContent,
          kinds: $("stats-kinds").textContent, recent: $("stats-recent").textContent },
        indexing: { current: state.indexStatus, history: progressHistory, visible: !$indexStatus.hidden,
          title: $indexTitle.textContent, count: $indexCount.textContent, detail: $indexDetail.textContent },
      },
    }).catch(() => {});
  }, 1500);
}

// Isolated release smoke: actual WebView controls, real helpers and persisted settings.
async function exerciseUiFeatures() {
  const wait = async (predicate) => {
    const deadline = Date.now() + 60000;
    while (!predicate() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 25));
    if (!predicate()) throw new Error("UI feature smoke timed out");
  };
  const language = async (value) => {
    const select = document.querySelector(".language-select");
    select.value = value; select.dispatchEvent(new Event("change", { bubbles: true }));
    await wait(() => !select.disabled && I18n.language === value);
  };
  const selectKind = (kind) => {
    const hit = [...state.strong, ...state.weaker].find((file) => file.kind === kind);
    if (!hit) throw new Error(`Missing real ${kind} fixture in search results`);
    if (state.weaker.includes(hit) && !state.showWeaker) toggleWeaker();
    const row = [...$list.querySelectorAll(".row")].find((node) => node.querySelector(".name").textContent === nameOf(hit.path));
    if (!row) throw new Error("Fixture row is not reachable through the results DOM");
    row.click();
  };
  // Existing indexed results can arrive before startup model verification finishes.
  // Capture the settled real indexing state rather than its transient startup banner.
  await wait(() => state.indexStatus?.stage === "idle");
  selectKind("doc");
  const snapshot = () => ({ groups: [...$list.querySelectorAll(".group-title")].map((node) => node.textContent), lang: document.documentElement.lang, query: $query.value,
    indexLabel: $("stats-toggle").textContent, graphLabel: $("graph-toggle").textContent,
    action: $preview.querySelector(".find-similar")?.textContent, selected: selectedHit()?.path });
  featureReport.initial = snapshot();
  await language("en"); featureReport.english = snapshot();
  await language("ru"); featureReport.russian = snapshot();
  $("graph-toggle").click(); await wait(() => !graph.loading);
  await wait(() => !!$("graph-preview").querySelector(".passage")?.textContent.includes("UIFEATURE742"));
  const controls = { initialZoom: graph.zoom, initialCenter: { ...graph.center } };
  $("graph-zoom-in").click(); controls.zoomIn = graph.zoom;
  $("graph-zoom").value = "75"; $("graph-zoom").dispatchEvent(new Event("input", { bubbles: true }));
  controls.sliderZoom = graph.zoom; controls.zoomLabel = $("graph-zoom-value").textContent;
  const mapRect = $("graph-map").getBoundingClientRect();
  $("graph-map").dispatchEvent(new MouseEvent("click", { clientX: mapRect.x + mapRect.width * .7, clientY: mapRect.y + mapRect.height * .65, bubbles: true }));
  controls.minimapCenter = { ...graph.center };
  $("graph-center").click(); controls.centered = { ...graph.center };
  const beforeInspector = graph.availableWidth();
  $("graph-inspector-toggle").click(); await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  controls.collapsedWidth = graph.availableWidth(); controls.beforeWidth = beforeInspector;
  $("graph-inspector-toggle").click(); await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  controls.inspectorRestored = graph.inspectorOpen;
  featureReport.controls = controls;
  if (isWindows) featureReport.documentsCapture = await invoke("debug_capture", { label: "documents" });
  featureReport.graph = graph.debug();
  featureReport.graph.bounds = ["graph-scene", "graph-preview", "graph-inspector"].map((id) => {
    const node = id === "graph-detail" ? document.querySelector(".graph-detail") : $(id), rect = node.getBoundingClientRect();
    return { id, x: rect.x, y: rect.y, width: rect.width, height: rect.height, bottom: rect.bottom };
  });
  $("graph-similar").click(); await wait(() => state.phase === "similar" && !!state.page || !!state.error);
  featureReport.similarFirst = { total: state.page?.total, loaded: state.strong.length, title: $("similar-title").textContent };
  while (state.page?.hasMore && !state.pageError) {
    $("load-more").click(); await wait(() => !state.loadingMore);
  }
  featureReport.similarAll = { total: state.page?.total, loaded: state.strong.length,
    paths: state.strong.map((hit) => hit.path), error: state.pageError || state.error,
    cosine: state.strong.map((hit) => hit.cosine), seed: state.related?.seed.path };
  $preview.querySelector(".find-similar").click();
  await wait(() => !!state.page && state.page.cursor !== `related-${state.generation - 1}`);
  featureReport.fromResult = { seed: state.related?.seed.path, selected: selectedHit()?.path, total: state.page?.total };
  $("similar-back").click();
  await wait(() => state.finalGeneration === state.generation && state.phase !== "similar");
  featureReport.back = snapshot();
  // Re-query the image fixture by its unique filename, then use the same graph button.
  $query.value = "UIFEATURE742-preview"; queryChanged();
  await wait(() => state.finalGeneration === state.generation);
  selectKind("image");
  $("graph-toggle").click(); await wait(() => !graph.loading);
  await wait(() => !!$("graph-preview").querySelector("img")?.naturalWidth);
  await wait(() => graph.svg.querySelectorAll('.graph-thumbnail[data-loaded="true"]').length >= 2);
  if (isWindows) featureReport.mediaCapture = await invoke("debug_capture", { label: "media" });
  featureReport.image = graph.debug();
  featureReport.image.assets = [...graph.model.nodes.values(), ...state.strong, ...state.weaker].map((hit) => ({ path: hit.path, url: fileURL(hit.path) }));
  const domClone = document.documentElement.cloneNode(true);
  domClone.querySelectorAll("script").forEach((node) => node.remove());
  const inputs = document.querySelectorAll("input"), selects = document.querySelectorAll("select");
  domClone.querySelectorAll("input").forEach((node, index) => node.setAttribute("value", inputs[index].value));
  domClone.querySelectorAll("select").forEach((node, index) => [...node.options].forEach((option, i) => option.toggleAttribute("selected", selects[index].selectedIndex === i)));
  featureReport.image.htmlSnapshot = "<!doctype html>" + domClone.outerHTML;
  featureReport.osint = await exerciseInvestigationUi(wait);
  graph.close();
  await language("en"); featureReport.englishAgain = snapshot();
  await language("ru");
  featureReport.final = snapshot();
}

// This drives real DOM controls with the actual indexed fixtures; backend responses are never stubbed.
async function exerciseInvestigationUi(wait) {
  const report = {}, seed = graph.selected;
  await wait(() => [...graph.model.nodes.values()].every((n) => n.unexpandedCount !== undefined));
  report.initial = graph.investigationDebug();
  const edge = [...graph.model.edges.values()].find((e) => e.matchTypes.includes("metadata") && e.matchTypes.includes("visual"));
  if (!edge) throw new Error("Missing real visual/EXIF fixture comparison");
  report.initialStatus = edge.status; report.initialPin = Number.isFinite(graph.model.nodes.get(seed).fx);
  const clickEdge = () => [...graph.svg.querySelectorAll("[data-edge]")].find((n) => n.dataset.edge === edge.id)?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  clickEdge();
  await wait(() => [...$("graph-match-previews").querySelectorAll("img")].filter((img) => img.naturalWidth).length === 2);
  report.comparison = { mode: graph.investigationDebug().mode, evidence: edge.evidence, previewCount: $("graph-match-previews").children.length };
  if (edge.status !== "confirmed") $("graph-confirm").click(); await graph.saveQueue;
  report.confirmed = edge.status;
  if (isWindows) report.comparisonCapture = await invoke("debug_capture", { label: "comparison" });
  $("graph-reject").click(); await graph.saveQueue;
  report.rejectedHidden = ![...graph.svg.querySelectorAll("[data-edge]")].some((n) => n.dataset.edge === edge.id);
  $("graph-show-rejected").checked = true; $("graph-show-rejected").dispatchEvent(new Event("change", { bubbles: true }));
  report.rejectedVisible = [...graph.svg.querySelectorAll("[data-edge]")].some((n) => n.dataset.edge === edge.id && n.classList.contains("rejected"));
  $("graph-unverify").click(); await graph.saveQueue; report.unverified = edge.status;
  $("graph-confirm").click(); await graph.saveQueue;
  $("graph-show-rejected").checked = false; $("graph-show-rejected").dispatchEvent(new Event("change", { bubbles: true }));
  const clickNode = (path) => [...graph.svg.querySelectorAll("[data-path]")].find((n) => n.dataset.path === path)?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  clickNode(seed);
  if (!Number.isFinite(graph.model.nodes.get(seed).fx)) {
    [...graph.svg.querySelectorAll("[data-path]")].find((n) => n.dataset.path === seed).querySelector("[data-node-tool]").dispatchEvent(new MouseEvent("click", { bubbles: true }));
  }
  await graph.saveQueue; report.pinned = { x: graph.model.nodes.get(seed).fx, y: graph.model.nodes.get(seed).fy };
  $("graph-layout").value = "timeline"; $("graph-layout").dispatchEvent(new Event("change", { bubbles: true }));
  report.timeline = { pinned: { x: graph.model.nodes.get(seed).x, y: graph.model.nodes.get(seed).y }, nodes: [...graph.model.nodes.values()].map(({ path, x, y, modified }) => ({ path, x, y, modified })) };
  if (isWindows) report.timelineCapture = await invoke("debug_capture", { label: "timeline" });
  $("graph-layout").value = "force"; $("graph-layout").dispatchEvent(new Event("change", { bubbles: true }));
  const other = [...graph.model.nodes.values()].find((n) => n.path !== seed);
  $("graph-omnibar").value = nameOf(other.path); $("graph-omnibar").dispatchEvent(new Event("input", { bubbles: true }));
  report.filenameFilter = [...graph.svg.querySelectorAll("[data-path]")].map((n) => ({ path: n.dataset.path, opacity: n.style.opacity }));
  $("graph-omnibar").value = "green hills and a tree beneath the sun"; $("graph-omnibar").dispatchEvent(new Event("input", { bubbles: true }));
  $("graph-search-form").dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  await wait(() => !graph.searchBusy); report.semantic = { error: graph.searchError, resultCount: graph.semanticMatches?.size, threshold: graph.semanticThreshold };
  $("graph-omnibar").value = "tree"; $("graph-omnibar").dispatchEvent(new Event("input", { bubbles: true }));
  $("graph-search-form").dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  $("graph-omnibar").value = "new filename query"; $("graph-omnibar").dispatchEvent(new Event("input", { bubbles: true }));
  await graph.semanticTask; report.staleQueryIgnored = graph.omnibar === "new filename query" && graph.semanticMatches === null && !graph.searchBusy;
  $("graph-omnibar").value = ""; $("graph-omnibar").dispatchEvent(new Event("input", { bubbles: true }));
  document.querySelector('[data-graph-modality="visual"]').click();
  report.visualOnly = graph.investigationDebug().visibleEdges.every((e) => e.matchTypes.includes("visual"));
  await faceSearch.status();
  report.faceDisabled = document.querySelector('[data-graph-modality="face"]').disabled;
  report.faceControlTruthful = report.faceDisabled === !(faceSearch.index?.models_ready && faceSearch.index?.worker_available);
  // Face availability now depends on the real model/runtime, so this historical
  // graph smoke checks the affordance without leaving its current workspace.
  document.querySelector('[data-graph-modality="all"]').click();
  const context = (path) => [...graph.svg.querySelectorAll("[data-path]")].find((n) => n.dataset.path === path).dispatchEvent(new MouseEvent("contextmenu", { clientX: 430, clientY: 420, bubbles: true, cancelable: true }));
  context(other.path); report.contextItems = [...$("graph-context").querySelectorAll("button")].map((n) => n.textContent);
  if (isWindows) report.contextCapture = await invoke("debug_capture", { label: "context" });
  [...$("graph-context").querySelectorAll("button")].find((n) => n.textContent === t("Hide node")).click();
  report.hidden = graph.model.nodes.get(other.path).hidden && ![...graph.svg.querySelectorAll("[data-path]")].some((n) => n.dataset.path === other.path);
  $("graph-restore-hidden").click(); await graph.saveQueue; report.restored = !graph.model.nodes.get(other.path).hidden;
  context(seed); [...$("graph-context").querySelectorAll("button")].find((n) => n.textContent === t("Find shortest path to…")).click();
  $("graph-path-target").value = other.path; $("graph-path-find").click(); report.path = $("graph-path-result").textContent;
  report.pathNodes = graph.pathResult ? [...graph.pathResult.nodes] : null; $("graph-path-cancel").click();
  clickNode(seed); $("graph-hash").click(); await wait(() => !graph.hashPending.size); report.hash = graph.investigationDebug().hash;
  const initialFiles = graph.model.nodes.size;
  context(seed); [...$("graph-context").querySelectorAll("button")].find((n) => n.textContent === t("Expand all links")).click();
  await wait(() => !graph.loading); report.expandAll = { before: initialFiles, after: graph.model.nodes.size, pageHasMore: graph.pages.get(graph.pageKey(seed))?.has_more };
  const video = [...graph.model.nodes.values()].find((n) => n.kind === "video");
  context(video.path); [...$("graph-context").querySelectorAll("button")].find((n) => n.textContent === t("Audio")).click();
  await wait(() => !graph.loading);
  const audioEdge = [...graph.model.edges.values()].find((e) => e.matchTypes.includes("audio") && (e.from === video.path || e.to === video.path));
  if (!audioEdge) throw new Error("No actual audio evidence for the video fixtures");
  [...graph.svg.querySelectorAll("[data-edge]")].find((n) => n.dataset.edge === audioEdge.id).dispatchEvent(new MouseEvent("click", { bubbles: true }));
  report.audioAnalysis = { evidence: audioEdge.evidence, mode: graph.investigationDebug().mode,
    timeButtons: [...$("graph-match-evidence").querySelectorAll("button")].filter((b) => !b.disabled).length };
  document.querySelector('[data-graph-modality="all"]').click(); clickNode(seed);
  await graph.saveQueue; report.saved = await invoke("graph_annotations"); report.final = graph.investigationDebug();
  return report;
}

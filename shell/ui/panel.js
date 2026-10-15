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
  if (visible && faceSearch.visible) faceSearch.close(false);
  if (visible) state.statsOpen = false;
  render();
}, onFaces: (hit) => openFaces(hit) });
const faceSearch = new FaceSearchView({ ask, invoke, rendered, fileURL, picture, nameOf, clock, onVisibility: (visible, restore) => {
  if (visible) {
    if (graph.visible) { facesReturnGraph = true; graph.close(); }
    state.statsOpen = false;
  } else {
    if (restore && facesReturnGraph) { graph.visible = true; graph.render(); }
    facesReturnGraph = false;
  }
  render();
}, onGraph: (seed, reply, minimum) => graph.showFaceMatches(seed, reply, minimum) });
window.faceSearch = faceSearch;
function openFaces(hit = selectedHit()) { return faceSearch.open(hit); }
const debugPages = [];

// MARK: Searching

function queryChanged() {
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
  document.querySelector(".panel").classList.toggle("graph-active", graph.visible);
  document.querySelector(".panel").classList.toggle("faces-active", facesVisible);
  document.documentElement.classList.toggle("graph-mode", graph.visible);
  document.documentElement.classList.toggle("faces-mode", facesVisible);
  const height = graph.visible || facesVisible ? 900 : empty && !state.statsOpen ? FIELD_HEIGHT + INDEX_HEIGHT : PANEL_HEIGHT;
  if (height !== state.height) {
    state.height = height;
    invoke("panel_height", { height, graph: graph.visible || facesVisible }).catch(() => {});
  }
  $body.hidden = empty || state.statsOpen || graph.visible || facesVisible;
  $footer.hidden = empty || state.statsOpen || graph.visible || facesVisible;
  $("graph-view").hidden = !graph.visible;
  $("faces-view").hidden = !facesVisible;
  $("faces-toggle").setAttribute("aria-expanded", String(facesVisible));
  $("similar-context").hidden = !state.related || graph.visible || state.statsOpen || facesVisible;
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

function rendered(path, kind, loc, pixels) {
  const key = `${path}|${kind}|${loc}|${pixels}`;
  if (!renders.has(key)) renders.set(key, ask({ op: "render", path, kind, loc, pixels }).then((reply) => reply.image));
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
  if (faceSearch.visible) faceSearch.close(false);
  if (graph.visible) graph.close();
  state.statsOpen = !state.statsOpen;
  render();
  if (state.statsOpen) refreshStats();
});
$("graph-toggle").addEventListener("click", () => graph.visible ? graph.close() : graph.show(selectedHit(), state.isCode));
$("faces-toggle").addEventListener("click", () => faceSearch.visible ? faceSearch.close() : openFaces(graph.visible ? graph.model.nodes.get(graph.selected) : selectedHit()));
$("graph-reveal").textContent = t("Show in {manager}", { manager: fileManager() });
$("similar-back").onclick = backFromSimilar;
tauri.event.listen("search-scope-changed", () => { if (faceSearch.visible) faceSearch.close(false); faceSearch.file = null; faceSearch.selection.clear(); if (graph.visible) graph.close(); if (state.related) queryChanged(); });
$("stats-refresh").addEventListener("click", refreshStats);
setInterval(() => { if (state.statsOpen && !document.hidden && !$("stats-refresh").disabled) refreshStats(); }, 10000);

document.addEventListener("keydown", (event) => {
  if (event.isComposing) return; // an input method is composing: its keys
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

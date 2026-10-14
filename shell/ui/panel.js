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
const MOD = isMac ? "⌘" : "Ctrl+";
const FILE_MANAGER = isMac ? "Finder" : isWindows ? "Explorer" : "Files";
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
  statsOpen: false,
  stats: null,
  statsGeneration: 0,
};
let debugPending = false;
const progressHistory = [];
let progressQueued = false;
let debugOptions = {};
const debugPages = [];

// MARK: Searching

function queryChanged() {
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
        if (debugPending) completeDebugSearch();
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
    const reply = await ask({ op: "search_page", cursor: page.cursor, offset: page.offset, limit: PAGE_SIZE });
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
    if (generation === state.generation) state.pageError = String(error);
  } finally {
    if (generation === state.generation) { state.loadingMore = false; renderPaging(); renderFooter(); }
  }
}

function renderPaging() {
  const page = state.page;
  $("more-controls").hidden = !page?.hasMore;
  $("load-more").disabled = state.loadingMore;
  $("load-more").textContent = state.loadingMore ? "Loading…" : page?.expired ? "Refresh results" : "Show more";
  $("page-status").textContent = state.pageError || (page ? `${state.strong.length + state.weaker.length} of ${page.total.toLocaleString()} matches loaded` : "");
}

async function refreshStats() {
  const generation = ++state.statsGeneration;
  $("stats-refresh").disabled = true;
  $("stats-message").textContent = "Loading index statistics…";
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
    const n = (value) => value.toLocaleString();
    $("stats-totals").replaceChildren();
    for (const [label, value] of [["Searchable files", n(totals.searchable)], ["Waiting to index", n(totals.pending)],
      ["Long files still being read", n(totals.partial)], ["Unsupported RAW files", n(totals.raw)],
      ["Other failed files", n(Math.max(0, totals.failed - totals.raw))], ["Skipped files", n(totals.skipped)],
      ["Indexed fragments / vectors", `${n(totals.segments)} / ${n(totals.vectors)}`],
      ["Database storage (including retained files)", formatBytes(totals.bytes)]]) {
      $("stats-totals").append(element("dt", "", label), element("dd", "", value));
    }
    $("stats-kinds").replaceChildren();
    for (const [kind, values] of [...kinds].sort((a, b) => b[1].searchable - a[1].searchable || a[0].localeCompare(b[0]))) {
      const row = element("tr", "");
      row.append(element("th", "", KIND_TITLE[kind] || kind));
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
    $("stats-message").textContent = kinds.size ? `${n(reply.folders + reply.code_folders)} selected folders · ${state.indexStatus?.stage === "idle" ? "Watching for changes" : "Indexing status shown above"}` : "No files in the selected folders have reached the index yet.";
    if (!recent.length) $("stats-recent").append(element("p", "overview-note", "No indexed files yet."));
    const latest = Math.max(0, ...(reply.indexes || []).map((index) => index.last_indexed || 0));
    $("stats-stamp").textContent = `Updated ${new Date(reply.sampled_at * 1000).toLocaleTimeString()}`
      + (latest ? ` · Last file indexed ${new Date(latest * 1000).toLocaleString()}` : "")
      + ". Counts cover selected folders; database storage covers the whole saved index.";
  } catch (error) {
    if (generation === state.statsGeneration) $("stats-message").textContent = `Statistics unavailable: ${String(error)}. Try Refresh.`;
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
  state.error = String(error);
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
  const height = empty && !state.statsOpen ? FIELD_HEIGHT + INDEX_HEIGHT : PANEL_HEIGHT;
  if (height !== state.height) {
    state.height = height;
    invoke("panel_height", { height }).catch(() => {});
  }
  $body.hidden = empty || state.statsOpen;
  $footer.hidden = empty || state.statsOpen;
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
    $list.append(element("div", "group-title", group.title));
    for (const hit of group.rows) $list.append(row(hit));
  }
  if (state.weaker.length) {
    const fold = element("div", "weaker" + (state.showWeaker ? " open" : "") + (state.selection === WEAKER ? " selected" : ""));
    fold.innerHTML = ICONS.chevron;
    const count = state.weaker.length;
    fold.append(state.showWeaker ? "Weaker matches" : `${count} weaker ${count === 1 ? "match" : "matches"}`);
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
      $preview.append(message("Search your code", "Say what the code does, or type a name that's in it."));
    } else if (state.indexing) {
      $preview.append(message("Nothing yet", "Still indexing. Until a file is read, "
        + "DigUp finds it only by its name."));
    } else if (state.isCode) {
      $preview.append(message("No good matches in your code", "Try saying what the code does, or a name that's in it."));
    } else {
      $preview.append(message("No good matches", "Try what you'd see or hear in it, or words you remember from it."));
    }
    return;
  }
  if (state.selection === WEAKER) {
    const count = state.weaker.length;
    $preview.append(message(state.showWeaker ? "Weaker matches" : `${count} weaker ${count === 1 ? "match" : "matches"}`,
      "They match much less well than the results above. Press Return to " + (state.showWeaker ? "fold them away." : "show them.")));
    return;
  }
  const hit = selectedHit();
  if (!hit) return;
  $preview.append(picture(hit), facts(hit));
}

/// The big picture: the photo or screenshot, the frame at the moment (it plays from there), the page, what's heard
/// at the moment, or the passage that matched.
function picture(hit) {
  const frame = element("div", "picture");
  const image = element("img");
  image.alt = "";
  frame.append(image);
  switch (hit.kind) {
    case "image":
    case "screenshot":
      if (SHOWN_AS_IS.has(extensionOf(hit.path))) image.src = fileURL(hit.path);
      else rendered(hit.path, "image", null, 1024).then((path) => { image.src = fileURL(path); }).catch(() => {});
      return frame;
    case "pdf":
      rendered(hit.path, "pdf", hit.loc ?? 1, 1024).then((path) => { image.src = fileURL(path); }).catch(() => {});
      return frame;
    case "video": {
      // The frame at the moment, its time on it; a click plays the video from there.
      const at = hit.loc ?? 0;
      rendered(hit.path, "video", at, 1024).then((path) => { image.src = fileURL(path); }).catch(() => {});
      const moment = element("div", "moment");
      const play = element("div", "play");
      play.innerHTML = ICONS.play;
      moment.append(image, play, element("span", "at", clock(at)));
      frame.replaceChildren(moment);
      frame.onclick = () => {
        const video = element("video");
        video.src = `${fileURL(hit.path)}#t=${at}`;
        video.controls = true;
        video.autoplay = true;
        frame.replaceChildren(video);
      };
      return frame;
    }
    case "audio": {
      const audio = element("div", "audio-picture");
      audio.innerHTML = ICONS.audio;
      const player = element("audio");
      player.src = `${fileURL(hit.path)}#t=${hit.loc ?? 0}`;
      player.controls = true;
      player.preload = "metadata";
      audio.append(player);
      frame.replaceChildren(audio);
      return frame;
    }
    default: {
      const passage = element("div", "passage" + (hit.kind === "code" ? " code" : ""));
      passage.textContent = (hit.excerpt ?? "").replace(/[«»]/g, "");
      ask({ op: "text", segment: hit.segment_id, code: state.isCode })
        .then((reply) => { if (reply.text) passage.innerHTML = highlighted(reply.text, state.text); })
        .catch(() => {});
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
  const open = element("button", "", "Open");
  open.onclick = openSelected;
  const reveal = element("button", "", `Show in ${FILE_MANAGER}`);
  reveal.onclick = revealSelected;
  buttons.append(open, reveal);
  box.append(buttons);
  return box;
}

function renderFooter() {
  const strong = state.strong.length, weaker = state.weaker.length;
  let summary;
  if (state.error) summary = `DigUp's helper: ${state.error}`;
  else if (state.phase === "words") {
    summary = state.encoder === "starting" ? "Matching words; meaning search is warming up…" : "Matching words…";
  } else if (state.phase === "wordsOnly") summary = "Words only: meaning search isn't available";
  else if (state.phase === "codeHint") summary = "Searching your code";
  else summary = state.page ? `${strong + weaker} of ${state.page.total.toLocaleString()} matches loaded`
    : `${strong} ${strong === 1 ? "result" : "results"}` + (weaker ? ` · ${weaker} weaker` : "");
  // Results while indexing are partial: say so where they're counted.
  if (state.indexing && !state.error) summary += " · indexing is still in progress";
  $summary.textContent = summary;
  $summary.title = state.page ? "Matches are ranked from the index at query time. Run the query again to include newer changes." : "";
  $keys.textContent = `↩ Open   ${MOD}↩ Show in ${FILE_MANAGER}`;
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
    case "page_image": return `p. ${Math.trunc(hit.loc)}`;
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
  const what = hit.segment === "cells" ? ["cell", "cells"] : ["line", "lines"];
  return first === last ? `${what[0]} ${first}` : `${what[1]} ${first}–${last}`;
}

/// Why it's here, in a few words: "Matches the picture", "Matches the frame at 0:06".
function reasonOf(hit) {
  const meaning = (hit.z ?? 0) >= 2, words = hit.keyword_rank != null;
  if (!meaning) return words ? "Has your words" : "Matches its name";
  const at = hit.loc != null ? clock(hit.loc) : "";
  const page = hit.loc != null ? `page ${Math.trunc(hit.loc)}` : "a page";
  switch (hit.segment) {
    case "image": return hit.kind === "screenshot" ? "Matches what's on screen" : "Matches the picture";
    case "ocr": return "Matches the text in it";
    case "frame": return `Matches the frame at ${at}`;
    case "audio": return hit.kind === "video" ? `Matches the sound at ${at}` : `Matches what's heard at ${at}`;
    case "page": return `Matches the text on ${page}`;
    case "page_image": return `Matches ${page}`;
    case "chunk": return "Matches its text";
    case "lines":
    case "cells": return `Matches ${span(hit) ?? "the code"}`;
    default: return "Matches its name";
  }
}

/// "Screenshot · Oct 7, 2026 · 1440 × 900 · 62 KB", "PDF · … · 463 pages, 120 read so far · 23 MB"
function details(hit) {
  const info = hit.info || {};
  const parts = [KIND_TITLE[hit.kind] || "File", dateOf(hit.modified)];
  if (info.width && info.height) parts.push(`${info.width} × ${info.height}`);
  const readTo = info.read_to != null ? Number(info.read_to) : null;
  if (info.pages) {
    const pages = Number(info.pages);
    parts.push((pages === 1 ? "1 page" : `${pages.toLocaleString()} pages`) + (readTo != null ? `, ${readTo} read so far` : ""));
  } else if (readTo != null) parts.push("partly read so far");
  if (info.lines) parts.push(Number(info.lines) === 1 ? "1 line" : `${Number(info.lines).toLocaleString()} lines`);
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
  return new Date(seconds * 1000).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

/// Sizes the way file managers count them (1 KB = 1,000 bytes): "62 KB", "2.1 MB".
function bytes(count) {
  if (count < 1000) return `${count} bytes`;
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
  state.statsOpen = !state.statsOpen;
  render();
  if (state.statsOpen) refreshStats();
});
$("stats-refresh").addEventListener("click", refreshStats);
setInterval(() => { if (state.statsOpen && !document.hidden) refreshStats(); }, 10000);

document.addEventListener("keydown", (event) => {
  if (event.isComposing) return; // an input method is composing: its keys
  if (event.target.closest?.("button")) return; // native Tab/Space/Enter behavior for page and overview controls
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
  $indexTitle.textContent = "Index status unavailable";
  $indexDetail.textContent = "Close and reopen the search panel to check again.";
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
    starting: "Starting indexing…", scanning: s.code ? "Scanning code folders…" : "Scanning folders…",
    indexing: s.code ? "Indexing source code" : "Indexing files", rest: "Reading the rest of long files",
    idle: s.failed || s.unavailable || s.message ? "Indexing finished with issues" : "Indexing complete",
    paused: "Indexing paused", waiting: "Waiting for the model", error: "Indexing needs attention",
    stopped: "Indexing stopped", "no-folders": "No folders selected",
  };
  const details = {
    starting: "Preparing the local index. Files already indexed remain searchable.",
    scanning: "Checking for new, changed and deleted files. Earlier results stay searchable.",
    indexing: "Files become searchable as they are indexed. Counts are for this pass.",
    rest: "Long files are read in parts. Counts are for the remaining parts in this pass.",
    idle: "Watching the selected folders for changes.",
    paused: "Choose Index Now / Resume in the tray to continue. Your index is saved.",
    waiting: "Indexing starts when the local model is ready.",
    error: "Check folder access and the processing device, then resume from the tray.",
    stopped: "Choose Index Now / Resume in the tray to try again.",
    "no-folders": "Choose Folders… in the tray to start indexing.",
  };
  const number = (n) => n.toLocaleString();
  const counted = Number.isFinite(s.done) && Number.isFinite(s.total);
  const overall = [s.searchable != null ? `${number(s.searchable)} files searchable` : "",
    s.pending != null ? `${number(s.pending)} remaining` : ""].filter(Boolean).join(" · ");
  const raw = Math.min(s.failed || 0, s.unsupported_raw || 0);
  const failedFiles = Math.max(0, (s.failed || 0) - raw);
  $indexStatus.dataset.stage = s.stage;
  $indexTitle.textContent = titles[s.stage] || "Indexing";
  $indexCount.textContent = counted ? `${number(s.done)} of ${number(s.total)} ${s.unit} processed this pass` : overall;
  const problems = [failedFiles ? `${number(failedFiles)} ${failedFiles === 1 ? "file" : "files"} couldn't be indexed` : "",
    raw ? `${number(raw)} RAW ${raw === 1 ? "file" : "files"} not supported` : "",
    s.skipped ? `${number(s.skipped)} files skipped` : "",
    s.unavailable ? `${number(s.unavailable)} folders unavailable` : ""].filter(Boolean).join(" · ");
  $indexDetail.textContent = [problems, s.message, counted ? overall : "", s.message ? "" : details[s.stage]]
    .filter(Boolean).join(" · ");
  $indexDetail.title = $indexDetail.textContent;
  $indexProgress.hidden = !counted || s.total === 0 || s.done > s.total || !["indexing", "rest"].includes(s.stage);
  if (!$indexProgress.hidden) {
    $indexProgress.max = s.total;
    $indexProgress.value = s.done;
    $indexProgress.setAttribute("aria-valuetext", $indexCount.textContent);
  }
}

render();

tauri.path.homeDir().then((home) => { state.home = home.replace(/[\\/]$/, ""); }).catch(() => {});

// Debug runs (--debug-query): type the query in, and once the meaning results and their pictures are in, report
// what the panel shows.
function debugSearch(query) {
  if (!query) return;
  debugPending = true;
  $query.value = query;
  queryChanged();
}
Promise.all([invoke("debug_search_options"), invoke("debug_query")]).then(([options, query]) => {
  debugOptions = options;
  debugSearch(query);
});
tauri.event.listen("debug-query", ({ payload }) => debugSearch(payload));   // after setup's first index

async function completeDebugSearch() {
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

// DigUp's setup window: what to search and the shortcut, with the model downloading in the background from the moment
// it opens (the shell starts that), as the Mac app's onboarding does. Folders show what's in them (`digup estimate`):
// counts, not times, until the estimates are measured on more than the Mac.
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const isMac = /Mac/.test(navigator.platform);
const isWindows = /Win/.test(navigator.platform);
const PAGES = ["welcome", "folders", "shortcut", "ready"];

const $ = (id) => document.getElementById(id);
const folders = new Map();   // path → {checked, row, counts}
const codeFolders = new Map();
let page = 0;
let estimateGeneration = 0;
let applying = false;
let info = { offered: [], chosen: [], hotkey: "", model: { state: "checking" }, auto: false };

async function start() {
  await I18n.ready;
  info = await invoke("setup_info");
  // The usual folders, then any chosen before (Choose Folders… after setup). On a first launch they start checked,
  // all but Downloads (much of what lands there is passing through).
  const chosen = new Set(info.chosen);
  const firstTime = chosen.size === 0 && !(info.codeRoots || []).length;
  for (const path of info.offered) addFolder(path, firstTime ? !/[\\/]Downloads$/i.test(path) || info.auto : chosen.has(path));
  for (const path of info.chosen) if (!folders.has(path)) addFolder(path, true);
  for (const path of info.codeRoots || []) addFolder(path, true, true);
  const estimating = estimate();
  showModel(info.model);
  tauri.event.listen("model", ({ payload }) => showModel(payload));
  showKeys(info.hotkey);
  $("startup-option").hidden = !info.autostartSupported;
  $("launch-at-login").checked = !!info.autostart;
  $("device").value = info.device || "auto";
  $("device").disabled = !!info.deviceOverridden;
  showDevice();
  if (!firstTime) page = 1;   // Choose Folders…: straight to the folders
  const asked = PAGES.indexOf(new URLSearchParams(location.search).get("page"));   // dev snapshots: ?page=folders
  if (asked >= 0) page = asked;
  render();
  if (info.auto) {
    await estimating;
    setTimeout(clickThrough, 500);
  }
}

// MARK: Pages

function render() {
  PAGES.forEach((name, index) => { $(name).hidden = index !== page; });
  $("back").hidden = page === 0;
  $("next").textContent = page === PAGES.length - 1 ? t("Start") : t("Continue");
  $("next").disabled = page === 1 && !chosenFolders().length && !chosenCodeFolders().length;
}

$("next").addEventListener("click", async () => {
  if (page < PAGES.length - 1) {
    page += 1;
    render();
    return;
  }
  $("next").disabled = true;
  $("next").textContent = t("Applying…");
  $("back").disabled = true;
  applying = true;
  ++estimateGeneration;
  try {
    if (info.auto) {
      await invoke("debug_setup_snapshot", { report: {
        reconfigure: !!info.debugReconfigure,
        folders: [...folders].map(([path, folder]) => ({ path, checked: folder.checked,
          counts: folder.counts.textContent, estimate: folder.estimate || null })),
        language: I18n.language, startLabel: $("next").textContent,
        codeRoots: chosenCodeFolders(), device: $("device").value,
      } });
    }
    await invoke("finish_setup", {
      folders: chosenFolders(),
      codeRoots: chosenCodeFolders(),
      launchAtLogin: info.auto || !info.autostartSupported ? null : $("launch-at-login").checked,
      device: info.deviceOverridden ? null : $("device").value,
    });
  } catch (error) {
    applying = false;
    $("model").textContent = String(error);
    $("back").disabled = false;
    estimate();
    render();
  }
});

$("back").addEventListener("click", () => {
  page = Math.max(0, page - 1);
  render();
});

/// Debug runs (--debug-setup): every offered folder, every page, then Start.
async function clickThrough() {
  if (info.debugReconfigure) {
    // The second smoke setup adds an offered folder through the same checkbox/change
    // path as a person; finish_setup still saves and reconfigures the real helpers.
    for (const folder of folders.values()) {
      const checkbox = folder.row.querySelector("input");
      if (!checkbox.checked) checkbox.click();
    }
  }
  while (page < PAGES.length - 1) {
    $("next").click();
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  if (info.debugUiFeatures) {
    const select = document.querySelector(".language-select");
    select.value = "ru"; select.dispatchEvent(new Event("change", { bubbles: true }));
    const deadline = Date.now() + 10000;
    while ((I18n.language !== "ru" || select.disabled) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 25));
    if (I18n.language !== "ru") throw new Error("Setup language switch failed");
  }
  // Exercise the same select and finish_setup path as a person using the installed WebView.
  if (info.debugDevice) {
    if ($("device").disabled) throw new Error("A launch override prevents the device selection smoke test");
    $("device").value = info.debugDevice;
    $("device").dispatchEvent(new Event("change", { bubbles: true }));
  }
  $("next").click();
}

// MARK: Folders

function addFolder(path, checked, forCode = false) {
  const collection = forCode ? codeFolders : folders;
  const row = document.createElement("label");
  row.className = "folder";
  const box = document.createElement("input");
  box.type = "checkbox";
  box.checked = checked;
  box.addEventListener("change", () => {
    collection.get(path).checked = box.checked;
    render();
  });
  const text = document.createElement("div");
  text.className = "text";
  const name = document.createElement("div");
  name.className = "name";
  name.textContent = path.split(/[\\/]/).filter(Boolean).pop() || path;
  const where = document.createElement("div");
  where.className = "path";
  where.textContent = isWindows ? path.replaceAll("/", "\\") : path;
  text.append(name, where);
  const counts = document.createElement("div");
  counts.className = "counts";
  counts.textContent = forCode ? t("Search with code:") : t("Counting…");
  row.append(box, text, counts);
  $(forCode ? "code-folder-list" : "folder-list").append(row);
  collection.set(path, { checked, row, counts });
}

function chosenFolders() {
  return [...folders].filter(([, folder]) => folder.checked).map(([path]) => path);
}

function chosenCodeFolders() {
  return [...codeFolders].filter(([, folder]) => folder.checked).map(([path]) => path);
}

async function estimate() {
  if (applying) return;
  // A new request cancels the previous helper. Include its unfinished rows so none stay at t("Counting…").
  const paths = [...folders].filter(([, folder]) => !folder.estimate).map(([path]) => path);
  if (!paths.length) return;
  const generation = ++estimateGeneration;
  let answers = [];
  try {
    answers = await invoke("estimate", { folders: paths });
  } catch (error) {
    if (generation !== estimateGeneration || applying) return;
    for (const path of paths) folders.get(path).counts.textContent = t("Couldn't read folder");
    $("model").textContent = String(error);
    return;
  }
  if (answers === null || generation !== estimateGeneration || applying) return;
  for (const path of paths) {
    const answer = answers.find((item) => item.requestedFolder === path);
    folders.get(path).estimate = answer;
    folders.get(path).counts.textContent = answer ? countsText(answer) : t("Couldn't match this folder's estimate");
  }
}

/// "1,204 pictures · 37 PDFs · 12 documents · 3 videos"
function countsText(answer) {
  if (answer.readable === false) return t("Can't read it");
  const files = answer.files || {};
  const part = (count, key) => count ? t(key, { count: count.toLocaleString(I18n.locale()) }) : null;
  const parts = [
    part((files.image || 0) + (files.screenshot || 0), "{count} pictures"),
    part(files.pdf, "{count} PDFs"),
    part(files.doc, "{count} documents"),
    part(files.audio, "{count} recordings"),
    part(files.video, "{count} videos"),
  ].filter(Boolean);
  return parts.length ? parts.join(" · ") : t("Nothing DigUp searches in it");
}

$("add-folder").addEventListener("click", async () => {
  try {
    const picked = (await invoke("pick_folders")).filter((path) => !folders.has(path));
    for (const path of picked) addFolder(path, true);
    if (picked.length) estimate();
    render();
  } catch (error) { $("model").textContent = String(error); }
});

// Native window destruction owns cancellation; this prevents a late IPC response touching a departing document.
window.addEventListener("pagehide", () => { ++estimateGeneration; });

$("add-code-folder").addEventListener("click", async () => {
  try {
    const picked = (await invoke("pick_folders")).filter((path) => !codeFolders.has(path));
    for (const path of picked) addFolder(path, true, true);
    render();
  } catch (error) { $("model").textContent = String(error); }
});

// MARK: The shortcut and the model

function showDevice() {
  const descriptions = {
    auto: t("Uses an available GPU and falls back to CPU if it cannot start."),
    cpu: t("Uses the processor. No compatible graphics driver is needed."),
    gpu: t("Requires a compatible GPU. If it cannot start, choose Auto or CPU."),
  };
  $("device-help").textContent = info.deviceOverridden
    ? t("The processing device is fixed for this launch. Restart without the device override to change it.")
    : descriptions[$("device").value] + t(" Changing this restarts processing and keeps your index.");
}

$("device").addEventListener("change", showDevice);

function showKeys(hotkey) {
  const keys = isMac ? [...hotkey.replace(/[^⌃⌥⇧⌘]/g, "")].concat(hotkey.replace(/[⌃⌥⇧⌘]/g, "")) : hotkey.split("+");
  $("keys").replaceChildren(...keys.filter(Boolean).map((key) => {
    const cap = document.createElement("span");
    cap.className = "key";
    cap.textContent = key;
    return cap;
  }));
  $("reveal-key").textContent = isMac ? "⌘↩" : "Ctrl+↩";
  $("reveal-text").textContent = isMac ? t("shows it in Finder") : isWindows ? t("shows it in Explorer") : t("shows it in its folder");
}

function showModel(model) {
  info.model = model;
  const megabytes = (bytes) => Math.round(bytes / 1e6).toLocaleString(I18n.locale());
  const lines = {
    checking: t("Checking the model…"),
    waiting: t("Waiting for the network to download the model"),
    ready: t("Model ready"),
    failed: t("The model couldn't download: {error}", { error: model.message || t("unknown error") }),
  };
  let text = lines[model.state] || "";
  if (model.state === "downloading") {
    text = model.total
      ? t("Downloading the model · {percent}% of {size} MB", { percent: Math.floor((100 * model.bytes) / model.total), size: megabytes(model.total) })
      : t("Downloading the model…");
    if (model.problem) text += t(" ({problem}, trying again)", { problem: model.problem });
  }
  $("model").textContent = text;
  $("retry-model").hidden = model.state !== "failed";
}

$("retry-model").addEventListener("click", () => invoke("retry_model").catch((error) => {
  $("model").textContent = String(error);
}));

document.addEventListener("ui-language-changed", () => {
  render(); showModel(info.model); showDevice(); showKeys(info.hotkey);
  for (const folder of folders.values()) folder.counts.textContent = folder.estimate ? countsText(folder.estimate) : t("Counting…");
  for (const folder of codeFolders.values()) folder.counts.textContent = t("Search with code:");
});
start().catch((error) => { $("model").textContent = String(error); });

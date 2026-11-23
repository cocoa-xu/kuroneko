"use strict";
// The virtual disk's dialog: the library, what is in the drives, uploads.
// Both pages open it: KuronekoDisk.open({ drive, onClose }), `drive` being
// the drive to insert into, and `onClose` what to do once it closes.
// KuronekoDisk.describe(medium) says how a drive holds its medium.
window.KuronekoDisk = (() => {
  const ERRORS = {
    busy: "The virtual disk is busy: wait until it is done.",
    eject_first: "Eject the writable folder first: its changes go back to it then.",
    in_use: "That is in the drive or in use.",
    exists: "There is one of that name already.",
    invalid_name: "The library does not take that name.",
    enoent: "That is not in the library any more.",
    file_too_large: "A file is larger than 4 GiB, more than FAT32 holds: choose exFAT.",
    no_exfat: "This NanoKVM's system has no exFAT: update it, or choose FAT32.",
    disc_unsupported: "This NanoKVM's system has CD drives only: update it, or choose CD-ROM.",
    bad_name: (data) => `“${data.name}” has a character drives do not take (" * : < > ? \\ |): rename it first.`,
    no_room: "Not enough free space on the NanoKVM.",
    no_storage: "The virtual disk is off: turn it on under USB on the device page.",
    cd_only: "A CUE sheet is a CD: insert it as Auto or CD-ROM.",
    cue: (data) => `The CUE sheet cannot go in: ${data.detail}.`,
    tracks_unsupported: "This NanoKVM's system has no CDs of tracks: update it.",
    no_maker: "That maker is not on this NanoKVM any more.",
    not_offered: "That maker does not offer this mode for it.",
  };
  const FILESYSTEMS = { exfat: "exFAT", fat32: "FAT32" };
  const DRIVES = { cd: "CD-ROM", dvd: "DVD-ROM", bd: "BD-ROM" };
  const DISCS = { cd: "CD", dvd: "DVD", bd: "Blu-ray" };
  const BOOTS = { bios: "BIOS", uefi: "UEFI", other: "other firmware" };

  const MARKUP = `
    <form method="dialog">
      <h3>Virtual disk</h3>
      <div data-part="drives"></div>
      <p class="note" data-part="busy" hidden></p>
      <div class="disklist" data-part="list"></div>
      <div class="note disktarget">
        <label data-part="targetlabel" hidden>Insert into <select data-part="target"></select></label>
        <label><input type="checkbox" data-part="remember" checked> Insert it again after the
          NanoKVM restarts</label>
      </div>
      <div class="diskupload">
        <button type="button" class="btn small" data-part="addfiles">Upload images…</button>
        <button type="button" class="btn small" data-part="addfolder">Upload a folder…</button>
        <button type="button" class="btn small" data-part="stop" hidden>Stop</button>
        <span class="muted" data-part="progress"></span>
        <input type="file" data-part="files" multiple hidden>
        <input type="file" data-part="folder" webkitdirectory hidden>
      </div>
      <p class="note">An image goes in as what it holds: a disc image on the disc its format belongs on
        (CD, DVD or Blu-ray), any other image as a USB drive; the line under each image says what was
        found, and the choice can be forced. A folder goes in as a drive made from it: read-only, the
        computer sees the folder as it was; writable, what the computer changes comes back to the
        folder when the drive is ejected. Folders are exFAT drives, or FAT32 for BIOS updates, UEFI and
        older systems, which holds files of at most 4 GiB. Eject the drive on the computer before
        ejecting it here. The library is <code>/data/images</code> on the NanoKVM, which SFTP reaches
        too. <span data-part="free"></span></p>
      <p class="note error" data-part="error" hidden></p>
      <menu><button type="button" class="btn" data-part="close">Close</button></menu>
    </form>`;

  let dialog = null, part = null;
  let timer = null, shown = "", disk = null, uploading = null, wanted = null, closed = null;
  const choices = {};

  const node = (tag, props, ...children) => {
    const e = Object.assign(document.createElement(tag), props || {});
    e.append(...children.filter((c) => c != null));
    return e;
  };
  const bytesText = (n) => n >= 1e9 ? `${(n / 1e9).toFixed(1)} GB` : n >= 1e6 ? `${(n / 1e6).toFixed(1)} MB`
    : n >= 1e3 ? `${Math.round(n / 1e3)} kB` : `${n} B`;
  const errorText = (code, data) => {
    const text = ERRORS[code];
    return typeof text === "function" ? text(data || {}) : text || code;
  };
  const showError = (message) => { part.error.textContent = message || ""; part.error.hidden = !message; };

  // How an item can go in, the first being the default; then what makers offer.
  function modes(item) {
    const made = (item.makers || []).map((o) => [`maker:${o.maker}:${o.mode}`, o.label]);
    if (item.kind === "folder") {
      return [["exfat-ro", "exFAT, read-only"], ["exfat-rw", "exFAT, writable"],
              ["fat32-ro", "FAT32, read-only"], ["fat32-rw", "FAT32, writable"], ...made];
    }
    const disc = item.format && item.format.disc;
    if (item.format && item.format.cue) return [["auto", "Auto: CD-ROM"], ...made];
    return [["auto", disc ? `Auto: ${DRIVES[disc]}` : "Auto: USB drive, writable"],
            ["cd", "CD-ROM"], ["dvd", "DVD-ROM"], ["bd", "BD-ROM"],
            ["drive-ro", "USB drive, read-only"], ["drive-rw", "USB drive, writable"], ...made];
  }

  // What an image holds, from its own structures.
  function formatText(f) {
    if (!f) return "";
    if (f.cue) {
      if (f.cue.error) return `CUE sheet the drive cannot take: ${f.cue.error}`;
      const tracks = [f.cue.data && `${f.cue.data} data`, f.cue.audio && `${f.cue.audio} audio`].filter(Boolean);
      return `CUE sheet: a CD of ${tracks.join(" and ")} track${f.cue.data + f.cue.audio > 1 ? "s" : ""}`;
    }
    const parts = [];
    const systems = [f.iso9660 && "ISO 9660", f.joliet && "Joliet", f.udf && `UDF ${f.udf}`].filter(Boolean);
    if (f.disc) {
      parts.push(`${DISCS[f.disc]} format` + (systems.length ? ` (${systems.join(", ")})` : "") +
        (f.layers === 2 ? ", two layers" : ""));
    }
    if (f.boot && f.boot.length) parts.push(`boots ${f.boot.map((b) => BOOTS[b] || b).join(" and ")}`);
    if (f.partitions) {
      parts.push(`${f.partitions.toUpperCase()} partition table` + (f.disc ? ": boots as a USB drive too" : ""));
    } else if (!f.disc) {
      parts.push("no disc format or partition table found");
    }
    return parts.join("; ");
  }

  function insertBody(item, mode) {
    const body = { name: item.name, remember: part.remember.checked };
    if (!part.targetlabel.hidden) body.drive = +part.target.value;
    const offer = (item.makers || []).find((o) => mode === `maker:${o.maker}:${o.mode}`);
    if (offer) {
      body.maker = offer.maker;
      body.mode = offer.mode;
    } else if (item.kind === "folder") {
      body.filesystem = mode.split("-")[0];
      body.read_only = !mode.endsWith("rw");
    } else if (mode.startsWith("drive")) {
      body.media = "drive";
      body.read_only = mode.endsWith("ro");
    } else {
      body.media = mode;
    }
    return body;
  }

  async function refresh() {
    try {
      disk = await (await fetch("/api/disk")).json();
      render(disk);
    } catch (e) {
      showError(`Virtual disk: ${e.message}`);
    }
  }

  async function act(path, body) {
    showError("");
    try {
      const reply = await fetch(path, { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify(body) });
      const data = await reply.json().catch(() => ({}));
      if (!reply.ok) showError(errorText(data.error, data) || `HTTP ${reply.status}`);
    } catch (e) {
      showError(e.message);
    }
    refresh();
  }

  function describeMedium(m) {
    const access = m.read_only ? "read-only" : "writable";
    const kept = m.remember ? ", in again after a restart" : "";
    if (m.label) return `${m.label}, ${access}${kept}`;
    return m.kind === "folder" ? `folder as ${FILESYSTEMS[m.filesystem] || "a drive"}, ${access}${kept}`
      : `${m.cdrom ? DRIVES[m.disc] || "CD-ROM" : "USB drive"}${m.tracks ? ` of ${m.tracks} tracks` : ""}, ${access}${kept}`;
  }

  // A drive by number, and by its storage device when there are several.
  const driveName = (s, d) => s.drives.length < 2 ? "The drive"
    : new Set(s.drives.map((x) => x.storage)).size > 1 ? `Drive ${d.drive + 1} (${d.storage})` : `Drive ${d.drive + 1}`;

  // The list is drawn anew only when it changes, so that a choice being made stays.
  function render(s) {
    const busy = s.busy;
    if (busy) {
      const percent = busy.total ? ` ${Math.floor((100 * busy.done) / busy.total)}%` : "";
      const into = s.drives.length > 1 ? ` for drive ${busy.drive + 1}` : "";
      part.busy.textContent = busy.action === "making"
        ? `Making a drive from ${busy.name}${into}:${percent}` : `Copying the changes back to ${busy.name}:${percent}`;
    }
    part.busy.hidden = !busy;
    part.free.textContent = `${bytesText(s.free)} free on the NanoKVM.`;
    if (s.error) showError(s.error);
    const now = JSON.stringify([s.items, s.drives, busy && [busy.action, busy.name]]);
    if (now === shown) return;
    shown = now;
    part.drives.replaceChildren(...(s.drives.length ? s.drives : [null]).map((d) => {
      if (!d) return node("span", { textContent: "There is no drive: turn the virtual disk on under USB on the device page." });
      const m = d.medium;
      return node("div", { className: "diskdrive" },
        node("span", { textContent: m ? `${driveName(s, d)}: ${m.name} (${describeMedium(m)})`
          : `${driveName(s, d)} is empty.` }),
        m ? node("button", { type: "button", className: "btn small", textContent: "Eject", disabled: !!busy,
          onclick: () => act("/api/disk/eject", { drive: d.drive }) }) : null);
    }));
    renderTarget(s);
    part.list.replaceChildren(...s.items.map((item) => row(item, s)));
  }

  // Where Insert puts an item when there are several drives: the drive the
  // dialog was opened for, else the first empty one, unless chosen.
  function renderTarget(s) {
    const chosen = wanted ?? part.target.value;
    wanted = null;
    part.targetlabel.hidden = s.drives.length < 2;
    part.target.replaceChildren(...s.drives.map((d) =>
      new Option(`${driveName(s, d)}${d.medium ? `, ${d.medium.name}` : ", empty"}`, String(d.drive))));
    const empty = s.drives.find((d) => !d.medium);
    part.target.value = chosen !== "" && s.drives.some((d) => String(d.drive) === String(chosen)) ? String(chosen)
      : String(empty ? empty.drive : 0);
  }

  function row(item, s) {
    const holder = s.drives.find((d) => d.medium && d.medium.name === item.name);
    const busyHere = !!s.busy && s.busy.name === item.name;
    const mode = node("select", { title: item.kind === "folder"
        ? "How the computer sees it. exFAT holds files of any size; FAT32 is for BIOS updates, UEFI and older systems."
        : "How the computer sees it. Auto follows what the image holds; the others force it.",
      onchange: (e) => { choices[item.name] = e.target.value; } },
      ...modes(item).map(([value, label]) => new Option(label, value)));
    if (choices[item.name]) mode.value = choices[item.name];
    const insert = node("button", { type: "button", className: "btn small", textContent: "Insert", disabled: !!s.busy, onclick: () =>
      act("/api/disk/insert", insertBody(item, mode.value)) });
    const remove = node("button", { type: "button", className: "btn small", textContent: "Delete", disabled: !!holder || busyHere,
      onclick: () => confirm(`Delete “${item.name}” from the NanoKVM?`) && act("/api/disk/delete", { name: item.name }) });
    return node("div", { className: "diskrow" },
      node("span", { className: "name", textContent: item.name, title: item.name }),
      node("span", { className: "muted", textContent: item.kind === "folder" ? "Folder" : "Image" }),
      node("span", { className: "muted", textContent: bytesText(item.size) }),
      holder ? node("span", { className: "muted",
        textContent: s.drives.length > 1 ? `In drive ${holder.drive + 1}` : "In the drive" }) : mode,
      holder ? null : insert,
      remove,
      item.format ? node("span", { className: "muted diskinfo", textContent: formatText(item.format) }) : null);
  }

  function uploadOne(file, name, replace, onProgress) {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      uploading = xhr;
      xhr.open("PUT", `/api/disk/files?name=${encodeURIComponent(name)}${replace ? "&replace=1" : ""}`);
      xhr.setRequestHeader("content-type", "application/octet-stream");
      xhr.upload.onprogress = (e) => onProgress(e.loaded);
      xhr.onload = () => {
        let data = {};
        try { data = JSON.parse(xhr.responseText); } catch (_) {}
        if (xhr.status < 300) resolve();
        else reject(Object.assign(new Error(errorText(data.error) || `HTTP ${xhr.status}`), { code: data.error }));
      };
      xhr.onerror = () => reject(new Error("the upload broke off"));
      xhr.onabort = () => reject(Object.assign(new Error("stopped"), { code: "stopped" }));
      xhr.send(file);
    });
  }

  async function uploadAll(entries, replace) {
    if (!entries.length) return;
    const total = entries.reduce((sum, e) => sum + e.file.size, 0);
    const buttons = [part.addfiles, part.addfolder];
    buttons.forEach((b) => { b.disabled = true; });
    part.stop.hidden = false;
    showError("");
    let sent = 0;
    try {
      for (const [i, e] of entries.entries()) {
        const onProgress = (loaded) => {
          part.progress.textContent = `${e.name}, ${i + 1} of ${entries.length}: ` +
            `${Math.floor((100 * (sent + loaded)) / Math.max(total, 1))}%`;
        };
        try {
          await uploadOne(e.file, e.name, replace, onProgress);
        } catch (err) {
          if (err.code !== "exists" || !confirm(`“${e.name}” is on the NanoKVM already. Replace it?`)) throw err;
          await uploadOne(e.file, e.name, true, onProgress);
        }
        sent += e.file.size;
        refresh();
      }
    } catch (err) {
      if (err.code !== "stopped") showError(`Upload: ${err.message}`);
    } finally {
      uploading = null;
      part.progress.textContent = "";
      buttons.forEach((b) => { b.disabled = false; });
      part.stop.hidden = true;
      refresh();
    }
  }

  function build() {
    dialog = node("dialog", { id: "diskdialog" });
    dialog.innerHTML = MARKUP;
    part = Object.fromEntries([...dialog.querySelectorAll("[data-part]")].map((e) => [e.dataset.part, e]));
    part.addfiles.onclick = () => part.files.click();
    part.addfolder.onclick = () => part.folder.click();
    part.stop.onclick = () => uploading && uploading.abort();
    part.files.onchange = () => {
      const entries = [...part.files.files].map((file) => ({ file, name: file.name }));
      part.files.value = "";
      uploadAll(entries, false);
    };
    // A folder's files, without hidden ones such as .DS_Store, which the library does not take.
    part.folder.onchange = () => {
      const entries = [...part.folder.files].map((file) => ({ file, name: file.webkitRelativePath }))
        .filter((e) => !e.name.split("/").some((p) => p.startsWith(".")));
      part.folder.value = "";
      if (!entries.length) return;
      const top = entries[0].name.split("/")[0];
      const there = disk && disk.items.some((item) => item.name === top);
      if (there && !confirm(`“${top}” is on the NanoKVM already. Add to it, replacing files of the same name?`)) return;
      uploadAll(entries, there);
    };
    part.close.onclick = () => dialog.close();
    dialog.addEventListener("close", () => {
      clearInterval(timer);
      timer = null;
      if (closed) closed();
    });
    document.body.append(dialog);
  }

  async function open({ drive = null, onClose = null } = {}) {
    if (!dialog) build();
    wanted = drive;
    closed = onClose;
    showError("");
    shown = "";
    await refresh();
    dialog.showModal();
    clearInterval(timer);
    timer = setInterval(refresh, 1500);
  }

  return { open, describe: describeMedium };
})();

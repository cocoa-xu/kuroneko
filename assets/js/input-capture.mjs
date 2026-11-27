export function createInputCapture({ document: doc, keyboard, root, picture, send,
  reset, changed, focusLocal, schedule = setTimeout, cancel = clearTimeout }) {
  let generation = 0, wantedPointer = null, hadPointer = false, hadFullscreen = false;
  let keyboardState = "off", escapeTimer = null, disposed = false, entering = false;
  const pressed = new Set();
  const fullscreen = () => doc.fullscreenElement === root;
  const locked = () => doc.pointerLockElement === picture();
  const update = (message = "") => changed({ fullscreen: fullscreen(), locked: locked(), keyboard: keyboardState, message });
  const exitChord = (event) => event.code === "Escape" && event.shiftKey &&
    !event.ctrlKey && !event.altKey && !event.metaKey;

  function releaseKeys() {
    if (escapeTimer !== null) cancel(escapeTimer);
    escapeTimer = null;
    pressed.clear();
    reset();
    send({ type: "release" });
  }

  function release({ exit = false } = {}) {
    generation++;
    wantedPointer = null;
    keyboardState = "off";
    releaseKeys();
    keyboard?.unlock?.();
    if (locked()) doc.exitPointerLock();
    if (exit && fullscreen()) Promise.resolve(doc.exitFullscreen()).catch(() => update("Use the browser's fullscreen exit control."));
    update();
  }

  function exit() {
    release({ exit: true });
    focusLocal();
  }

  function lockPointer() {
    if (disposed) return Promise.resolve();
    const element = picture();
    wantedPointer = element;
    element.focus();
    try {
      return Promise.resolve(element.requestPointerLock()).catch(() => {
        wantedPointer = null;
        update("Mouse capture was not allowed. Click the picture to try again.");
      });
    } catch (_) {
      wantedPointer = null;
      update("Mouse capture is unavailable in this browser.");
      return Promise.resolve();
    }
  }

  async function enter({ pointer = false } = {}) {
    if (entering) return;
    if (disposed || !root.requestFullscreen) return update("Fullscreen is unavailable in this browser.");
    entering = true;
    const attempt = ++generation;
    // Fullscreen consumes activation; request pointer lock first, without awaiting it.
    const pointerRequest = pointer ? lockPointer() : Promise.resolve();
    let optionRead = false;
    try {
      if (!fullscreen()) {
        try {
          await root.requestFullscreen({ navigationUI: "hide", get keyboardLock() { optionRead = true; return "browser"; } });
        } catch (error) {
          if (error.name !== "NotSupportedError") throw error;
          optionRead = false;
          await root.requestFullscreen();
        }
      }
      if (disposed || attempt !== generation) {
        if (fullscreen()) await doc.exitFullscreen();
        return;
      }
      keyboardState = optionRead ? "requested" : "unavailable";
      if (keyboard?.lock) {
        try {
          await keyboard.lock();
          if (disposed || attempt !== generation) { keyboard.unlock(); return; }
          keyboardState = "on";
        } catch (_) { keyboardState = "denied"; }
      }
      await pointerRequest;
      if (disposed || attempt !== generation) return;
      picture().focus();
      update();
    } catch (_) {
      release();
      update("Fullscreen was not allowed. Use the Fullscreen button to try again.");
    } finally {
      entering = false;
    }
  }

  function key(event, down) {
    event.preventDefault();
    if (exitChord(event)) {
      if (down) exit();
      return;
    }
    if (event.code === "Escape" && (fullscreen() || locked()) &&
        keyboardState !== "on" && keyboardState !== "requested") {
      if (down) exit();
      return;
    }
    if (down) {
      if (event.repeat || pressed.has(event.code)) return;
      pressed.add(event.code);
      send({ type: "key", code: event.code, down: true });
      if (event.code === "Escape" && !event.ctrlKey && !event.altKey && !event.metaKey && !event.shiftKey && (fullscreen() || locked())) {
        escapeTimer = schedule(exit, 1500);
      }
    } else {
      if (event.code === "Escape" && escapeTimer !== null) { cancel(escapeTimer); escapeTimer = null; }
      if (!pressed.delete(event.code)) return;
      send({ type: "key", code: event.code, down: false });
      // macOS can omit a letter's keyup while Command is held.
      if (event.code === "MetaLeft" || event.code === "MetaRight") releaseKeys();
    }
  }

  return {
    enter, exit, release, releaseKeys, lockPointer, key,
    localKey(event) {
      if (exitChord(event) && (fullscreen() || locked() || doc.activeElement === picture())) {
        event.preventDefault();
        event.stopImmediatePropagation();
        exit();
      }
    },
    pointerChanged() {
      if (locked() && (!wantedPointer || disposed)) { doc.exitPointerLock(); return; }
      if (hadPointer && !locked()) {
        release({ exit: true });
        focusLocal();
      }
      hadPointer = locked();
      update();
    },
    pointerError() {
      wantedPointer = null;
      releaseKeys();
      update("Mouse capture was not allowed. You can still use the normal pointer.");
    },
    fullscreenChanged() {
      if (hadFullscreen && !fullscreen()) release();
      hadFullscreen = fullscreen();
      update();
    },
    dispose() { disposed = true; release({ exit: true }); },
  };
}

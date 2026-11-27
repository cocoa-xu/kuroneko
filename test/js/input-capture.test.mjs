import { test } from "node:test";
import assert from "node:assert/strict";
import { createInputCapture } from "../../assets/js/input-capture.mjs";

function fixture({ modern = false, denyKeyboard = false, legacy = true } = {}) {
  const calls = [], sent = [], states = [], timers = new Map();
  let next = 0;
  const doc = { fullscreenElement: null, pointerLockElement: null,
    exitFullscreen() { calls.push("exit"); this.fullscreenElement = null; return Promise.resolve(); },
    exitPointerLock() { calls.push("unpoint"); this.pointerLockElement = null; } };
  const root = { async requestFullscreen(options) {
    calls.push("fullscreen");
    if (modern) assert.equal(options.keyboardLock, "browser");
    doc.fullscreenElement = root;
  } };
  const picture = { focus() { calls.push("focus"); }, requestPointerLock() {
    calls.push("pointer"); doc.pointerLockElement = picture; return Promise.resolve();
  } };
  const keyboard = legacy ? {
    async lock() { calls.push("keyboard"); if (denyKeyboard) throw new Error("denied"); },
    unlock() { calls.push("unlock"); },
  } : null;
  const capture = createInputCapture({ document: doc, root, picture: () => picture, keyboard,
    send: (event) => sent.push(event), changed: (state) => states.push(state),
    reset: () => calls.push("reset"), focusLocal: () => calls.push("local"),
    schedule: (fn) => { timers.set(++next, fn); return next; }, cancel: (id) => timers.delete(id),
  });
  const key = (code, down, options = {}) => {
    const event = { code, preventDefault() {}, ...options };
    capture.key(event, down);
  };
  return { capture, doc, root, picture, calls, sent, states, timers, key, keyboard };
}

test("game entry requests pointer before fullscreen consumes activation", async () => {
  const f = fixture(); await f.capture.enter({ pointer: true });
  assert.ok(f.calls.indexOf("pointer") < f.calls.indexOf("fullscreen"));
  assert.ok(f.calls.indexOf("fullscreen") < f.calls.indexOf("keyboard"));
  assert.equal(f.states.at(-1).locked, true);
});

test("short Escape goes remote, holding it releases all input and exits locally", async () => {
  const f = fixture(); await f.capture.enter();
  f.key("Escape", true); f.key("Escape", false);
  assert.deepEqual(f.sent, [{ type: "key", code: "Escape", down: true }, { type: "key", code: "Escape", down: false }]);
  assert.equal(f.timers.size, 0);
  f.key("MetaLeft", true); f.key("Escape", true);
  [...f.timers.values()][0]();
  assert.equal(f.doc.fullscreenElement, null);
  assert.deepEqual(f.sent.at(-1), { type: "release" });
  assert.ok(f.calls.includes("local"));
});

test("Shift Escape is local even while a toolbar or dialog has focus", async () => {
  const f = fixture(); await f.capture.enter();
  f.key("ShiftLeft", true);
  let stopped = false;
  f.capture.localKey({ code: "Escape", shiftKey: true, preventDefault() {}, stopImmediatePropagation() { stopped = true; } });
  assert.equal(stopped, true);
  assert.equal(f.doc.fullscreenElement, null);
  assert.equal(f.sent.some((e) => e.code === "Escape"), false);
  assert.deepEqual(f.sent.at(-1), { type: "release" });
  f.key("ShiftLeft", false);
  assert.deepEqual(f.sent.at(-1), { type: "release" });
});

test("denied or unsupported keyboard capture leaves Escape local", async () => {
  for (const options of [{ denyKeyboard: true }, { legacy: false }]) {
    const f = fixture(options); await f.capture.enter();
    assert.equal(f.doc.fullscreenElement, f.root);
    f.key("Escape", true);
    assert.equal(f.doc.fullscreenElement, null);
    assert.equal(f.sent.some((e) => e.code === "Escape"), false);
  }
});

test("modern fullscreen keyboard option works without navigator.keyboard", async () => {
  const f = fixture({ modern: true, legacy: false }); await f.capture.enter();
  assert.equal(f.states.at(-1).keyboard, "requested");
  f.key("Escape", true); f.key("Escape", false);
  assert.equal(f.doc.fullscreenElement, f.root);
});

test("a fullscreen rejection never leaves the pointer captured", async () => {
  const f = fixture();
  f.root.requestFullscreen = async () => { throw new Error("denied"); };
  await f.capture.enter({ pointer: true });
  assert.equal(f.doc.pointerLockElement, null);
  assert.match(f.states.at(-1).message, /not allowed/);
});

test("an Escape during an outstanding keyboard permission cannot recapture later", async () => {
  const f = fixture(); let resolve;
  f.keyboard.lock = () => new Promise((done) => { resolve = done; });
  const enter = f.capture.enter({ pointer: true });
  await Promise.resolve();
  f.capture.exit();
  const unlocks = f.calls.filter((c) => c === "unlock").length;
  resolve(); await enter;
  assert.equal(f.doc.fullscreenElement, null);
  assert.equal(f.doc.pointerLockElement, null);
  assert.ok(f.calls.filter((c) => c === "unlock").length > unlocks);
});

test("late pointer lock after exit is immediately relinquished", async () => {
  const f = fixture(); f.picture.requestPointerLock = () => undefined;
  await f.capture.enter({ pointer: true }); f.capture.exit();
  f.doc.pointerLockElement = f.picture; f.capture.pointerChanged();
  assert.equal(f.doc.pointerLockElement, null);
});

test("browser unlock and fullscreen exit release held remote buttons and keys", async () => {
  const f = fixture(); await f.capture.enter({ pointer: true });
  f.capture.pointerChanged(); f.capture.fullscreenChanged(); f.key("KeyW", true);
  f.doc.pointerLockElement = null; f.capture.pointerChanged();
  assert.equal(f.doc.fullscreenElement, null);
  assert.deepEqual(f.sent.at(-1), { type: "release" });
  f.capture.fullscreenChanged();
  assert.ok(f.calls.includes("reset"));
});

test("Command release clears keys whose keyup macOS omitted", () => {
  const f = fixture(); f.key("MetaLeft", true); f.key("KeyQ", true); f.key("MetaLeft", false);
  assert.deepEqual(f.sent.at(-1), { type: "release" });
});

test("disposal releases capture and prevents subsequent entry", async () => {
  const f = fixture(); await f.capture.enter({ pointer: true }); f.capture.dispose();
  const before = f.calls.filter((c) => c === "fullscreen").length;
  await f.capture.enter();
  assert.equal(f.doc.fullscreenElement, null);
  assert.equal(f.doc.pointerLockElement, null);
  assert.equal(f.calls.filter((c) => c === "fullscreen").length, before);
});

test("Ctrl Shift Escape remains available to the remote Task Manager", async () => {
  const f = fixture(); await f.capture.enter();
  f.capture.localKey({ code: "Escape", ctrlKey: true, shiftKey: true, preventDefault() { throw new Error("not local"); } });
  f.key("Escape", true, { ctrlKey: true, shiftKey: true });
  f.key("Escape", false, { ctrlKey: true, shiftKey: true });
  assert.equal(f.doc.fullscreenElement, f.root);
  assert.deepEqual(f.sent.at(-1), { type: "key", code: "Escape", down: false });
  assert.equal(f.timers.size, 0);
});

test("repeated entry cannot race two permission prompts", async () => {
  const f = fixture(); let resolve;
  f.keyboard.lock = () => new Promise((done) => { resolve = done; });
  const enter = f.capture.enter(); await Promise.resolve();
  await f.capture.enter({ pointer: true });
  assert.equal(f.calls.filter((c) => c === "fullscreen").length, 1);
  resolve(); await enter;
});

test("Shift Escape also releases keyboard focus in windowed mode", () => {
  const f = fixture(); f.key("ShiftLeft", true); f.key("Escape", true, { shiftKey: true });
  assert.ok(f.calls.includes("local"));
  assert.deepEqual(f.sent.at(-1), { type: "release" });
  assert.equal(f.sent.some((e) => e.code === "Escape"), false);
});

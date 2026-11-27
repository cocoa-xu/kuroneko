import { test } from "node:test";
import assert from "node:assert/strict";
import { createPageScope } from "../../assets/js/page-scope.mjs";

test("unmount cancels timers, animation, listeners and reconnecting resources", () => {
  let next = 0, calls = 0, closed = 0;
  const pending = new Map();
  const schedule = (fn) => { pending.set(++next, fn); return next; };
  const cancel = (id) => pending.delete(id);
  const host = { setTimeout: schedule, clearTimeout: cancel, setInterval: schedule,
    clearInterval: cancel, requestAnimationFrame: schedule, cancelAnimationFrame: cancel };
  const scope = createPageScope(host), target = new EventTarget();
  scope.timeout(() => calls++, 5);
  scope.interval(() => calls++, 5);
  scope.animation(() => calls++);
  scope.listen(target, "sample", () => calls++);
  scope.own(() => { closed++; scope.timeout(() => calls++, 1000); });
  const alreadyQueued = [...pending.values()];
  scope.stop();
  scope.stop();
  for (const callback of alreadyQueued) callback();
  target.dispatchEvent(new Event("sample"));
  assert.equal(scope.active, false);
  assert.equal(pending.size, 0);
  assert.equal(calls, 0);
  assert.equal(closed, 1);
  scope.own(() => closed++);
  assert.equal(closed, 2);
});

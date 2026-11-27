export function createPageScope(host = globalThis) {
  let active = true;
  const cleanups = new Set(), timeouts = new Set(), intervals = new Set(), frames = new Set();
  const own = (cleanup) => {
    if (!active) cleanup();
    else cleanups.add(cleanup);
    return () => cleanups.delete(cleanup);
  };
  return {
    get active() { return active; },
    own,
    timeout(fn, ms) {
      if (!active) return 0;
      const id = host.setTimeout(() => {
        timeouts.delete(id);
        if (active) fn();
      }, ms);
      timeouts.add(id);
      return id;
    },
    cancelTimeout(id) { timeouts.delete(id); host.clearTimeout(id); },
    interval(fn, ms) {
      if (!active) return 0;
      const id = host.setInterval(() => { if (active) fn(); }, ms);
      intervals.add(id);
      return id;
    },
    animation(fn) {
      if (!active) return 0;
      const id = host.requestAnimationFrame((t) => {
        frames.delete(id);
        if (active) fn(t);
      });
      frames.add(id);
      return id;
    },
    listen(target, type, fn, options) {
      if (!active) return;
      target.addEventListener(type, fn, options);
      own(() => target.removeEventListener(type, fn, options));
    },
    stop() {
      if (!active) return;
      active = false;
      for (const id of timeouts) host.clearTimeout(id);
      for (const id of intervals) host.clearInterval(id);
      for (const id of frames) host.cancelAnimationFrame(id);
      timeouts.clear(); intervals.clear(); frames.clear();
      for (const cleanup of cleanups) cleanup();
      cleanups.clear();
    },
  };
}

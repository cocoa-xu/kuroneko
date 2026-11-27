import { test } from "node:test";
import assert from "node:assert/strict";
import { createPacer, sampleVideo } from "../../assets/js/video-playback.mjs";

function fixture(smooth = true) {
  let time = 0, mode = smooth, next = 0, recoveries = 0;
  const timers = new Map(), decoded = [], observations = [];
  const pace = createPacer({
    decode: (chunk) => { decoded.push(chunk); return chunk !== "blocked"; },
    recover: () => recoveries++, observe: (sample) => observations.push(sample),
    smooth: () => mode, now: () => time,
    schedule: (fn, delay) => { timers.set(++next, { fn, due: time + delay }); return next; },
    cancel: (id) => timers.delete(id),
  });
  return { pace, decoded, observations, timers,
    recoveries: () => recoveries,
    put(chunk, made, arrived) { time = arrived; pace.put(chunk, BigInt(made * 1000), arrived); },
    mode(value) { mode = value; },
    tick(t) {
      time = t;
      for (const [id, timer] of [...timers]) {
        if (timer.due <= t) { timers.delete(id); timer.fn(); }
      }
    },
  };
}

test("latency mode decodes on arrival and still observes arrival variation", () => {
  const f = fixture(false);
  f.put(0, 0, 0);
  f.put(1, 10, 113);
  assert.deepEqual(f.decoded, [0, 1]);
  assert.deepEqual(f.observations.at(-1), { late: 103, delay: 0 });
  assert.equal(f.timers.size, 0);
});

test("a 103 ms stall cannot create more than 50 ms of smoothing", () => {
  const f = fixture();
  f.put(0, 0, 0);
  f.put(1, 10, 113);
  f.put(2, 120, 120);
  assert.deepEqual(f.decoded, [0, 1]);
  assert.equal(f.observations[1].delay, 50);
  f.tick(170);
  assert.deepEqual(f.decoded, [0, 1, 2]);
});

test("reset discards both pending frames and timing history", () => {
  const f = fixture();
  f.put(0, 0, 0);
  f.put(1, 10, 60);
  f.put(2, 70, 70);
  f.pace.clear();
  f.put(3, 10_000, 80);
  f.tick(1000);
  assert.deepEqual(f.decoded, [0, 1, 3]);
  assert.deepEqual(f.observations.at(-1), { late: 0, delay: 0 });
  assert.equal(f.timers.size, 0);
});

test("a throttled timer requests recovery instead of decoding stale references", () => {
  const f = fixture();
  f.put(0, 0, 0);
  f.put(1, 10, 60);
  f.put(2, 70, 70);
  f.tick(1000);
  assert.deepEqual(f.decoded, [0, 1]);
  assert.equal(f.recoveries(), 1);
  assert.equal(f.timers.size, 0);
});

test("decoder backpressure also stops a timer-driven batch", () => {
  const f = fixture();
  f.put(0, 0, 0);
  f.put(1, 10, 60);
  f.put("blocked", 70, 70);
  f.put(3, 80, 80);
  f.tick(130);
  assert.deepEqual(f.decoded, [0, 1, "blocked"]);
  assert.equal(f.timers.size, 0);
});

test("switching to latency mode flushes smoothing without another timer", () => {
  const f = fixture();
  f.put(0, 0, 0);
  f.put(1, 10, 60);
  f.put(2, 70, 70);
  f.mode(false);
  f.put(3, 80, 80);
  assert.deepEqual(f.decoded, [0, 1, 2, 3]);
  assert.equal(f.timers.size, 0);
});

test("sample rates use elapsed time when browser timers are throttled", () => {
  const t = { received: 2700, bytes: 3_750_000, gapMax: 112, decoded: 2670,
    decodeSum: 8010, decodeMax: 4, drawn: 2670, shown: 2600, drawMax: 0.4,
    queueMax: 8, lateMax: 103, recoveries: 1 };
  const b = sampleVideo(t, 30_000, { rtt: 12, delay: null }, false);
  assert.equal(b.received, 90);
  assert.equal(b.decoded, 89);
  assert.equal(b.mbit, 1);
  assert.equal(b.decode_ms, 3);
  assert.equal(b.elapsed_ms, 30_000);
  assert.equal(b.visible, 0);
});

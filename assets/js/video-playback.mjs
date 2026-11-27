export function createPacer({ decode, recover, observe, smooth,
  now = () => performance.now(), schedule = setTimeout, cancel = clearTimeout }) {
  let base = null, transits = [], delay = 0, queue = [], timer = null;

  function clear() {
    if (timer !== null) cancel(timer);
    timer = null;
    queue = [];
    base = null;
    transits = [];
    delay = 0;
  }

  function drain() {
    if (timer !== null) cancel(timer);
    timer = null;
    const t = now();
    if (queue.length && t - queue[0].arrived > 100) {
      clear();
      recover();
      return;
    }
    while (queue.length && queue[0].due <= t + 1) {
      if (decode(queue.shift().chunk) === false) {
        clear();
        return;
      }
    }
    if (queue.length) timer = schedule(drain, Math.max(0, queue[0].due - now()));
  }

  return {
    put(chunk, made, arrived) {
      let late = 0;
      if (made !== null) {
        if (base === null) base = made;
        const transit = arrived - Number(made - base) / 1000;
        transits.push(transit);
        if (transits.length > 150) transits.shift();
        late = Math.max(0, transit - Math.min(...transits));
      }
      // A rare stall must not turn into a quarter second of input lag.
      const smoothing = smooth() && made !== null;
      delay = smoothing ? Math.min(50, Math.max(late, delay - 0.5)) : 0;
      if (!smoothing) for (const frame of queue) frame.due = arrived;
      observe({ late, delay });
      queue.push({ chunk, arrived, due: delay ? arrived - late + delay : arrived });
      if (queue.length > 16) {
        clear();
        recover();
        return;
      }
      drain();
    },
    clear,
  };
}

export function sampleVideo(t, elapsed, connection, visible) {
  const seconds = Math.max(1, elapsed) / 1000;
  const rate = (n) => Math.round(n / seconds);
  return {
    type: "stats", elapsed_ms: Math.round(elapsed), visible: visible ? 1 : 0,
    received: rate(t.received), mbit: +(t.bytes * 8 / 1e6 / seconds).toFixed(2),
    gap_max_ms: Math.round(t.gapMax), decoded: rate(t.decoded),
    decode_ms: t.decoded ? +(t.decodeSum / t.decoded).toFixed(1) : 0,
    decode_max_ms: Math.round(t.decodeMax), drawn: rate(t.drawn), shown: rate(t.shown),
    draw_max_ms: +t.drawMax.toFixed(1), queue_max: t.queueMax,
    rtt_ms: connection.rtt == null ? undefined : Math.round(connection.rtt),
    delay_ms: connection.delay == null ? undefined : Math.round(connection.delay),
    late_max_ms: Math.round(t.lateMax), recoveries: t.recoveries,
  };
}

import { PcmQueue, PLAYER } from "./audio-playback.mjs";
import { createInputCapture } from "./input-capture.mjs";
import { createPageScope } from "./page-scope.mjs";
import { createPacer, sampleVideo } from "./video-playback.mjs";

// The KVM page's picture, input, sound and tools, which the browser runs.
// KuronekoWeb.KVMLive renders the page and its NanoKVM menu; the two talk
// through events: "menu" from here when that menu opens or closes,
// "kvm:restarting" from there, and "kvm:logout" and "kvm:password" from the
// menu, which change the session's cookie and so go as requests.
export const KVM = {
  mounted() {
    start(this);
  },
  destroyed() {
    this.stop?.();
  },
};

function start(hook) {
  const scope = createPageScope();
  const setTimeout = scope.timeout, clearTimeout = scope.cancelTimeout;
  const setInterval = scope.interval, requestAnimationFrame = scope.animation;
  const listen = scope.listen;
  const openSocket = (url) => {
    const ws = new WebSocket(url);
    const release = scope.own(() => ws.close());
    ws.addEventListener("close", release, { once: true });
    return ws;
  };
  const audioContext = (options) => {
    const ctx = new AudioContext(options);
    scope.own(() => { if (ctx.state !== "closed") ctx.close().catch(() => {}); });
    return ctx;
  };
  hook.stop = () => { hook.inputCapture?.dispose(); hook.stopVideo?.(); scope.stop(); };

  const canvas = document.getElementById("canvas");
  const img = document.getElementById("mjpeg");
  const notice = document.getElementById("notice");
  // The picture's and the input's connections, as one dot: green with both,
  // amber with one, red with neither; its title says which.
  const live = { video: false, input: false };
  const STATE_TEXT = {
    "true true": "Picture and input connected",
    "true false": "Picture connected, input connecting",
    "false true": "Input connected, no picture",
    "false false": "Connecting",
  };
  const mark = (id, on) => {
    live[id] = on;
    const dot = document.getElementById("state");
    dot.classList.toggle("on", live.video && live.input);
    dot.classList.toggle("part", live.video !== live.input);
    dot.title = STATE_TEXT[`${live.video} ${live.input}`];
  };
  const text = (id, s) => { document.getElementById(id).textContent = s; };
  // A switch in a popover; the sound tool lights while sound or the microphone is on.
  function switchOn(button, on) {
    button.setAttribute("aria-checked", String(on));
    const any = ["sound", "mic"].some((id) => document.getElementById(id).getAttribute("aria-checked") === "true");
    document.getElementById("soundtool").classList.toggle("on", any);
  }

  // ---- The bar's popovers: one open at a time, under its tool; a click elsewhere or Esc closes it ----
  let openPop = null;
  function closePop() {
    if (!openPop) return;
    if (openPop.pop.id === "pop-kvm") hook.pushEvent("menu", { open: false });
    openPop.pop.hidden = true;
    openPop.tool.classList.remove("open");
    openPop = null;
  }
  for (const tool of document.querySelectorAll("[data-pop]")) {
    listen(tool, "click", (e) => {
      e.stopPropagation();
      const pop = document.getElementById(`pop-${tool.dataset.pop}`);
      const again = openPop && openPop.pop === pop;
      closePop();
      if (again) return;
      pop.hidden = false;
      const r = tool.getBoundingClientRect();
      const left = Math.min(Math.max(8, r.left + r.width / 2 - pop.offsetWidth / 2), innerWidth - pop.offsetWidth - 8);
      pop.style.left = `${left}px`;
      tool.classList.add("open");
      openPop = { pop, tool };
      if (pop.id === "pop-kvm") hook.pushEvent("menu", { panel: "main", open: true });
    });
  }
  listen(document, "click", (e) => { if (openPop && !openPop.pop.contains(e.target)) closePop(); });
  listen(document, "keydown", (e) => { if (e.key === "Escape" && openPop) closePop(); });

  const wsUrl = (path) => `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}${path}`;
  let view = canvas;
  let decoded = 0;
  const naturalSize = () => view === canvas ? [canvas.width, canvas.height]
                                            : [img.naturalWidth, img.naturalHeight];

  // The video input as the device reports it: {width, height, fps}, "none",
  // "unsupported", or null until known.
  let input = null;
  const sameInput = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  // While the device restarts, keep saying so instead of what it last said.
  let restartingUntil = 0;
  const restarting = () => Date.now() < restartingUntil;
  function showInput(i) {
    if (restarting()) return;
    input = i;
    const problem = i === "none" ? "No signal" : i === "unsupported" ? "Unsupported input" : "";
    notice.textContent = problem;
    notice.hidden = !problem;
    text("size", i && typeof i === "object" ? `${i.width}×${i.height} ${i.fps} Hz`
      : i === null ? "Starting" : i === "unsupported" ? "Unsupported input" : "No signal");
  }
  hook.handleEvent("kvm:restarting", () => {
    closePop();
    restartingUntil = Date.now() + 10000;
    notice.textContent = "Restarting…";
    notice.hidden = false;
  });

  // The NanoKVM's own CPU, memory and network.
  const rate = (b) => b >= 1e6 ? `${(b / 1e6).toFixed(1)} MB/s`
                    : b >= 1e3 ? `${Math.round(b / 1e3)} kB/s` : `${Math.round(b)} B/s`;

  // The device page, in a tab of its own that later clicks reuse.
  const openDevice = (section) => window.open(`/device${section ? `#${section}` : ""}`, "kuroneko-device");

  function glyph(id, percent) {
    const bar = document.getElementById(id);
    bar.style.width = `${Math.min(100, Math.max(10, percent))}%`;
    bar.className = percent >= 85 ? "hot" : percent >= 60 ? "warm" : "";
  }

  function showSystem(s) {
    if (!s) return;
    glyph("cpuglyph", s.cpu.total);
    glyph("memglyph", s.memory.percent);

  }

  async function pollStatus() {
    try {
      const reply = await fetch("/status");
      // The session ended: the page becomes the login page.
      if (reply.status === 401) return location.reload();
      const status = await reply.json();
      showInput(status.video.input);
      showAudioMode(status.audio.mode);
      showSystem(status.metrics);
      document.getElementById("ocr").hidden = !status.ocr;
      showBluetooth(status.bluetooth);
      const hid = status.usb.includes("keyboard") && status.usb.includes("mouse");
      text("hint", !hid ? "Keyboard and mouse are off: turn them on in USB devices"
                   : mouseMode === "relative" ? "Click the picture to take the mouse, Esc lets go"
                   : "Click to control the computer. Shift + Esc releases control.");
    } catch (_) {}
  }
  setInterval(pollStatus, 2000);
  pollStatus();

  // The input's target: USB, or the Bluetooth keyboard and mouse once a
  // device paired with them listens.
  const targetGroup = document.getElementById("target");
  let lastBluetooth = null;
  function showTarget(bluetooth) {
    const host = bluetooth && bluetooth.host;
    for (const b of targetGroup.children) b.setAttribute("aria-pressed", String(b.dataset.target === target));
    document.getElementById("btbadge").hidden = target !== "bluetooth";
    text("targetnote", target !== "bluetooth" ? "The computer on USB"
      : host ? "The paired device that is connected"
      : "No paired device is connected: pair one on the device page");
  }
  function showBluetooth(bluetooth) {
    document.getElementById("targetfield").hidden = !bluetooth;
    if (!bluetooth && target === "bluetooth") chooseTarget("usb");
    showTarget(bluetooth);
    lastBluetooth = bluetooth;
  }
  function chooseTarget(next) {
    target = next;
    send({ type: "target", target });
    showTarget(lastBluetooth);
  }
  targetGroup.onclick = (e) => {
    const b = e.target.closest("button");
    if (b && b.dataset.target !== target) chooseTarget(b.dataset.target);
  };

  // The stream's codec, as its messages say: "h264" or "h265".
  let streamCodec = null;
  const CODECS = {
    h264: { label: "H.264", config: "avc1.42C033" },
    h265: { label: "H.265", config: "hvc1.1.6.L153.B0" },
  };

  let modeAt = performance.now();
  setInterval(() => {
    const now = performance.now(), seconds = (now - modeAt) / 1000;
    modeAt = now;
    if (view === canvas) {
      mark("video", decoded > 0);
      text("mode", `${streamCodec ? CODECS[streamCodec].label : "Video"} ${Math.round(decoded / seconds)} fps`);
      decoded = 0;
    } else {
      mark("video", img.naturalWidth > 0 && notice.hidden);
    }
  }, 1000);

  // H.264 or H.265 through WebCodecs when the browser can decode them, MJPEG
  // otherwise. The device takes H.265 when every viewer decodes it.
  async function start() {
    if ("VideoDecoder" in window) {
      const codecs = [];
      for (const codec of Object.keys(CODECS)) {
        const config = { codec: CODECS[codec].config, codedWidth: 3840, codedHeight: 2160 };
        const support = await VideoDecoder.isConfigSupported(config).catch(() => ({}));
        if (support.supported) codecs.push(codec);
      }
      if (codecs.length) return startVideo(codecs);
    }
    startMJPEG("MJPEG");
  }

  async function startMJPEG(mode) {
    if (!scope.active) return;
    view = img;
    canvas.hidden = true;
    quality.hidden = true;
    img.hidden = false;
    text("mode", mode);
    // The stream on its own port asks for the token of this boot.
    const token = async () => (await (await fetch("/status")).json()).mjpeg_token || "";
    const load = async () => {
      img.src = `http://${location.hostname}:8088/stream.mjpg?token=${await token().catch(() => "")}&t=${Date.now()}`;
    };
    img.onerror = () => setTimeout(load, 2000);
    load();
    attachInput(img);
  }

  // Draws the decoded frames. WebGL takes each as a texture from the
  // decoder's own memory; a 2D canvas, where there is no WebGL, may copy it
  // first, which for 4K can take longer than a frame lasts.
  function frameRenderer(canvas) {
    const gl = canvas.getContext("webgl2", { alpha: false, antialias: false, depth: false, stencil: false,
                                             powerPreference: "high-performance" });
    if (!gl) {
      const ctx = canvas.getContext("2d");
      return { name: "2D canvas", draw: (frame) => ctx.drawImage(frame, 0, 0) };
    }
    const shader = (type, source) => {
      const s = gl.createShader(type);
      gl.shaderSource(s, source);
      gl.compileShader(s);
      return s;
    };
    const program = gl.createProgram();
    gl.attachShader(program, shader(gl.VERTEX_SHADER, `#version 300 es
      in vec2 p; out vec2 uv;
      void main() { uv = vec2(p.x + 1.0, 1.0 - p.y) / 2.0; gl_Position = vec4(p, 0.0, 1.0); }`));
    gl.attachShader(program, shader(gl.FRAGMENT_SHADER, `#version 300 es
      precision mediump float; uniform sampler2D picture; in vec2 uv; out vec4 color;
      void main() { color = texture(picture, uv); }`));
    gl.linkProgram(program);
    gl.useProgram(program);
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    const p = gl.getAttribLocation(program, "p");
    gl.enableVertexAttribArray(p);
    gl.vertexAttribPointer(p, 2, gl.FLOAT, false, 0, 0);
    gl.bindTexture(gl.TEXTURE_2D, gl.createTexture());
    for (const [name, value] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR],
                                 [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) {
      gl.texParameteri(gl.TEXTURE_2D, name, value);
    }
    return {
      name: "WebGL",
      draw: (frame) => {
        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, frame);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      },
    };
  }

  // ---- Connection quality: each second, what the device did with the
  // picture, as it says, and what this browser did with it. The page tells
  // the device its side too (Kuroneko.ViewerStats).
  const connection = { device: null, rtt: null, renderer: null, delay: null };
  const second = () => ({ received: 0, bytes: 0, gapMax: 0, decoded: 0, decodeSum: 0, decodeMax: 0,
                          drawn: 0, shown: 0, drawMax: 0, queueMax: 0, lateMax: 0, recoveries: 0 });

  let playback = "latency";
  const playbackGroup = document.getElementById("playback");
  function showPlayback() {
    for (const b of playbackGroup.children) b.setAttribute("aria-pressed", String(b.dataset.playback === playback));
  }
  playbackGroup.onclick = (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    playback = b.dataset.playback;
    prefs.set("playback", playback);
    showPlayback();
  };

  let tally = second(), lastArrival = 0, drewThisFrame = false;
  // A frame drawn twice before the display refreshes shows only once.
  (function countShown() {
    if (drewThisFrame) { tally.shown++; drewThisFrame = false; }
    requestAnimationFrame(countShown);
  })();
  const connStats = document.getElementById("connstats");
  // This sum is an estimate, not a measurement of physical presentation.
  function screenDelay(d, b) {
    if (!d || d.ready_ms == null || b.rtt_ms == null || !b.decoded) return "–";
    return `about ${Math.round((d.socket_ms ?? d.ready_ms) + b.rtt_ms / 2 + (b.delay_ms || 0) + b.decode_ms + b.draw_max_ms)} ms`;
  }
  const statsTool = document.getElementById("statstool"), statsBox = document.getElementById("statsbox");
  // Where the stats go: inside the window, under the bar.
  function placeStats(x, y) {
    const r = statsBox.getBoundingClientRect(), top = document.getElementById("bar").offsetHeight;
    x = Math.min(Math.max(0, x), innerWidth - r.width);
    y = Math.min(Math.max(top, y), innerHeight - r.height);
    statsBox.style.left = `${x}px`;
    statsBox.style.top = `${y}px`;
  }
  function showStats(on) {
    statsBox.hidden = !on;
    statsTool.classList.toggle("on", on);
    statsTool.setAttribute("aria-pressed", String(on));
    if (on) {
      const r = statsBox.getBoundingClientRect();
      placeStats(r.left, r.top);
    }
  }
  const toggleStats = (on) => {
    prefs.set("stats", on);
    showStats(on);
  };
  statsTool.onclick = () => toggleStats(statsBox.hidden);
  document.getElementById("statsclose").onclick = () => toggleStats(false);
  // Dragged anywhere, and kept there. A press on it leaves the keyboard
  // with the picture.
  let statsDrag = null;
  listen(statsBox, "mousedown", (e) => e.preventDefault());
  listen(statsBox, "pointerdown", (e) => {
    if (e.target.closest("button")) return;
    const r = statsBox.getBoundingClientRect();
    statsDrag = { dx: e.clientX - r.left, dy: e.clientY - r.top };
    statsBox.setPointerCapture(e.pointerId);
    statsBox.classList.add("dragging");
  });
  listen(statsBox, "pointermove", (e) => {
    if (statsDrag) placeStats(e.clientX - statsDrag.dx, e.clientY - statsDrag.dy);
  });
  const endStatsDrag = () => {
    if (!statsDrag) return;
    statsDrag = null;
    statsBox.classList.remove("dragging");
    const r = statsBox.getBoundingClientRect();
    prefs.set("statsAt", { x: Math.round(r.left), y: Math.round(r.top) });
  };
  listen(statsBox, "pointerup", endStatsDrag);
  listen(statsBox, "pointercancel", endStatsDrag);
  listen(window, "resize", () => {
    if (!statsBox.hidden) {
      const r = statsBox.getBoundingClientRect();
      placeStats(r.left, r.top);
    }
  });
  function showConnection(b) {
    const d = connection.device;
    const per = (n) => (d && d.seconds ? Math.round(n / d.seconds) : n);
    const rows = [
      ["The NanoKVM"],
      ["Captured", d ? `${per(d.captured)} fps` : "–"],
      ["Encoded", d ? `${per(d.encoded)} fps, ${d.skipped} skipped` : "–"],
      ["Encoded bitrate", d?.seconds ? `${(d.bytes * 8 / d.seconds / 1e6).toFixed(2)} Mbit/s, ${d.keys} keys` : "–"],
      ...(d?.key_max_bytes == null ? [] : [["Largest key / delta", `${Math.round(d.key_max_bytes / 1024)} / ${Math.round(d.delta_max_bytes / 1024)} KiB`]]),
      ["Encode time", d ? `${d.encode_ms} ms, ${d.encode_max_ms} max` : "–"],
      ["Frame end to encoded", d && d.ready_ms != null ? `${d.ready_ms} ms, ${d.ready_max_ms} max` : "–"],
      ...[
        ["Writer wait", "writer_queue"], ["Bitstream copy", "copy"], ["Pipe write", "pipe"],
        ["Frame end to BEAM", "port"], ["Frame end to socket", "socket"],
      ].filter(([, field]) => d?.[`${field}_ms`] != null).map(([label, field]) =>
        [label, `${d[`${field}_ms`].toFixed(1)} ms, ${d[`${field}_max_ms`].toFixed(1)} max`]),
      ["QP", d ? `${d.qp}, ${d.qp_max} max` : "–"],
      ["This browser"],
      ["Received", `${b.received} fps, ${b.mbit} Mbit/s`],
      ["Longest wait", `${b.gap_max_ms} ms`],
      ["Arrival variation", `${b.late_max_ms} ms`],
      ["Decoded", `${b.decoded} fps, ${b.decode_ms} ms, ${b.decode_max_ms} max`],
      ["Shown", `${b.shown} of ${b.drawn}, ${connection.renderer || "–"}`],
      ["Smoothing", b.delay_ms == null ? "off" : `${b.delay_ms} ms`],
      ["Draw time", `${b.draw_max_ms} ms max`],
      ["Input round trip", b.rtt_ms == null ? "–" : `${b.rtt_ms} ms`],
      ["Estimated capture to draw", screenDelay(d, b)],
    ];
    connStats.replaceChildren(...rows.flatMap(([term, value]) => {
      if (value === undefined) return [Object.assign(document.createElement("div"), { className: "side", textContent: term })];
      return [Object.assign(document.createElement("dt"), { textContent: term }),
              Object.assign(document.createElement("dd"), { textContent: value })];
    }));
  }
  let sampleAt = performance.now();
  setInterval(() => {
    const now = performance.now(), elapsed = now - sampleAt;
    sampleAt = now;
    if (view !== canvas) return;
    const t = tally;
    tally = second();
    const sample = sampleVideo(t, elapsed, connection, !document.hidden);
    send(sample);
    send({ type: "ping", t: performance.now() });
    showConnection(sample);
  }, 1000);

  // Binary messages: a type, then an access unit. 1 and 2 an H.264 delta and
  // keyframe, 3 and 4 an H.265 delta and keyframe.
  const chunkCodec = (type) => (type <= 2 ? "h264" : "h265");

  function startVideo(codecs) {
    if (!scope.active) return;
    view = canvas;
    canvas.hidden = false;
    quality.hidden = false;
    loadQuality();
    const renderer = frameRenderer(canvas);
    connection.renderer = renderer.name;
    let stopped = false, socket = null, reconnect = null;
    const open = () => {
      if (stopped || document.hidden || socket) return;
      const ws = openSocket(wsUrl(`/video?codecs=${codecs.join(",")}&timestamps=1`));
      socket = ws;
      ws.binaryType = "arraybuffer";
      let synced = false;
      let streamInput;  // input of the stream this decoder gets
      const decoder = new VideoDecoder({
        output: (frame) => {
          if (stopped || !scope.active || document.hidden) { frame.close(); return; }
          const t = performance.now(), waited = t - frame.timestamp / 1000;
          tally.decoded++;
          tally.decodeSum += waited;
          tally.decodeMax = Math.max(tally.decodeMax, waited);
          if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
            canvas.width = frame.displayWidth;
            canvas.height = frame.displayHeight;
          }
          renderer.draw(frame);
          frame.close();
          tally.drawMax = Math.max(tally.drawMax, performance.now() - t);
          tally.drawn++;
          drewThisFrame = true;
          decoded++;
        },
        error: () => ws.close(),
      });
      const recover = () => {
        pace.clear();
        if (decoder.state === "configured") decoder.reset();
        synced = false;
        tally.recoveries++;
        if (streamCodec) decoder.configure({ codec: CODECS[streamCodec].config, optimizeForLatency: true });
        if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "keyframe" }));
      };
      const pace = createPacer({
        smooth: () => playback === "smooth",
        observe: ({ late, delay }) => {
          tally.lateMax = Math.max(tally.lateMax, late);
          connection.delay = playback === "smooth" ? delay : null;
        },
        recover,
        decode: (chunk) => {
          if (ws.readyState !== WebSocket.OPEN || decoder.state !== "configured") return false;
          tally.queueMax = Math.max(tally.queueMax, decoder.decodeQueueSize);
          if (decoder.decodeQueueSize >= 8) { recover(); return false; }
          try {
            decoder.decode(new EncodedVideoChunk({ ...chunk, timestamp: Math.round(performance.now() * 1000) }));
            return true;
          } catch (_) { recover(); return false; }
        },
      });
      // A new codec or input restarts the stream, from a keyframe.
      const reconfigure = (codec) => {
        pace.clear();
        if (decoder.state === "configured") decoder.reset();
        decoder.configure({ codec: CODECS[codec].config, optimizeForLatency: true });
        streamCodec = codec;
        synced = false;
      };
      ws.onmessage = (ev) => {
        if (stopped || !scope.active || document.hidden) return;
        if (typeof ev.data === "string") {
          const message = JSON.parse(ev.data);
          if ("stats" in message) {
            connection.device = message.stats;
            return;
          }
          if (!("input" in message)) return;
          if (streamInput !== undefined && !sameInput(message.input, streamInput) && streamCodec)
            reconfigure(streamCodec);
          streamInput = message.input;
          return showInput(message.input);
        }
        const arrived = performance.now();
        if (lastArrival) tally.gapMax = Math.max(tally.gapMax, arrived - lastArrival);
        lastArrival = arrived;
        tally.received++;
        tally.bytes += ev.data.byteLength;
        const data = new Uint8Array(ev.data);
        // The type, then the capture's frame-end time.
        const made = new DataView(ev.data).getBigInt64(1);
        const codec = chunkCodec(data[0]);
        const key = data[0] === 2 || data[0] === 4;
        if (codec !== streamCodec) {
          // Another viewer's setting can name a codec this browser lacks.
          if (!codecs.includes(codec)) {
            stopped = true;
            ws.close();
            return startMJPEG(`MJPEG: no ${CODECS[codec].label} here`);
          }
          reconfigure(codec);
        }
        if (!key && !synced) return;
        synced = true;
        pace.put({ type: key ? "key" : "delta", data: data.subarray(9) }, made, arrived);
      };
      ws.onclose = () => {
        socket = null;
        lastArrival = 0;
        pace.clear();
        if (decoder.state !== "closed") decoder.close();
        streamCodec = null;
        if (!stopped && !document.hidden) reconnect = setTimeout(open, 1000);
      };
    };
    const visibility = () => {
      clearTimeout(reconnect);
      tally = second();
      sampleAt = performance.now();
      lastArrival = 0;
      if (document.hidden) socket?.close();
      else if (socket?.readyState === WebSocket.CLOSING) reconnect = setTimeout(open, 100);
      else open();
    };
    listen(document, "visibilitychange", visibility);
    hook.stopVideo = () => {
      stopped = true;
      clearTimeout(reconnect);
      document.removeEventListener("visibilitychange", visibility);
      socket?.close();
    };
    open();
    attachInput(canvas);
  }

  let ws = null;
  let target = "usb";
  function connect() {
    ws = openSocket(wsUrl("/ws"));
    // Each connection starts on USB: tell it the target chosen.
    ws.onopen = () => { mark("input", true); send({ type: "target", target }); };
    ws.onmessage = (ev) => {
      try {
        const message = JSON.parse(ev.data);
        if (typeof message.pong === "number") connection.rtt = performance.now() - message.pong;
      } catch (_) {}
    };
    ws.onclose = () => { capture.release({ exit: true }); mark("input", false); setTimeout(connect, 1000); };
  }
  connect();
  const send = (event) => ws && ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify(event));
  const inputResets = new Set();
  const fullscreenButton = document.getElementById("fullscreen");
  const captureStatus = document.getElementById("capturestatus");
  let gameMouseMode = null, hadCapture = false;
  const restoreMouse = () => {
    if (gameMouseMode === null) return;
    mouseMode = gameMouseMode;
    gameMouseMode = null;
    showMouseMode();
  };
  const capture = createInputCapture({
    document, keyboard: navigator.keyboard, root: document.documentElement,
    picture: () => view, send,
    reset: () => { for (const reset of inputResets) reset(); wheelX = wheelY = 0; },
    focusLocal: () => fullscreenButton.focus(),
    schedule: setTimeout, cancel: clearTimeout,
    changed: ({ fullscreen, locked, keyboard, message }) => {
      document.documentElement.classList.toggle("kvm-fullscreen", fullscreen);
      document.documentElement.classList.toggle("pointer-captured", locked);
      fullscreenButton.setAttribute("aria-pressed", String(fullscreen));
      fullscreenButton.title = fullscreen ? "Exit fullscreen" : "Fullscreen";
      document.getElementById("fullscreenstrip").hidden = !fullscreen;
      const active = fullscreen || locked;
      if (hadCapture && !active) restoreMouse();
      hadCapture = active;
      if (!fullscreen) document.documentElement.classList.remove("fullscreen-tools");
      captureStatus.textContent = message || (keyboard === "on" || keyboard === "requested"
        ? "Keyboard capture requested. System shortcuts may still stay on this computer."
        : "Browser shortcuts are not captured. Use the remote key buttons.");
    },
  });
  hook.inputCapture = capture;
  fullscreenButton.disabled = !document.fullscreenEnabled;
  document.getElementById("gamecontrol").disabled = !document.fullscreenEnabled || !canvas.requestPointerLock;
  fullscreenButton.onclick = () => {
    closePop();
    if (document.fullscreenElement) capture.exit();
    else capture.enter();
  };
  document.getElementById("exitfullscreen").onclick = () => capture.exit();
  document.getElementById("fullscreentools").onclick = () => {
    capture.releaseKeys();
    document.documentElement.classList.toggle("fullscreen-tools");
  };
  document.getElementById("gamecontrol").onclick = () => {
    closePop();
    if (gameMouseMode === null) gameMouseMode = mouseMode;
    mouseMode = "relative";
    showMouseMode();
    capture.enter({ pointer: true }).then(() => {
      if (!document.fullscreenElement && !document.pointerLockElement) restoreMouse();
    });
  };
  listen(document, "fullscreenchange", () => capture.fullscreenChanged());
  listen(document, "pointerlockchange", () => capture.pointerChanged());
  listen(document, "pointerlockerror", () => capture.pointerError());
  listen(document, "keydown", (e) => capture.localKey(e), true);
  listen(window, "blur", () => capture.release({ exit: true }));
  listen(document, "visibilitychange", () => { if (document.hidden) capture.release({ exit: true }); });


  // Position inside the picture, which object-fit: contain may letterbox.
  function position(e) {
    const r = view.getBoundingClientRect();
    const [nw, nh] = naturalSize();
    const iw = nw || 16, ih = nh || 9;
    const scale = Math.min(r.width / iw, r.height / ih), w = iw * scale, h = ih * scale;
    const clamp = (v) => Math.min(1, Math.max(0, v));
    return { x: clamp((e.clientX - r.left - (r.width - w) / 2) / w),
             y: clamp((e.clientY - r.top - (r.height - h) / 2) / h) };
  }
  const mouse = (e, extra) => send({ type: "mouse", ...position(e), buttons: e.buttons, ...extra });

  // Absolute: the pointer goes where the mouse points. Relative: the pointer
  // is locked to the picture and the mouse moves by steps.
  let mouseMode = "absolute";
  const mouseModeGroup = document.getElementById("mousemode");
  function showMouseMode() {
    for (const b of mouseModeGroup.children) b.setAttribute("aria-pressed", String(b.dataset.mode === mouseMode));
  }
  mouseModeGroup.onclick = (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    capture.releaseKeys();
    gameMouseMode = null;
    mouseMode = b.dataset.mode;
    prefs.set("mouseMode", mouseMode);
    if (document.pointerLockElement) document.exitPointerLock();
    showMouseMode();
  };

  const localPointerGroup = document.getElementById("localpointer");
  function showLocalPointer(pointer) {
    document.body.dataset.localPointer = pointer;
    for (const b of localPointerGroup.children) b.setAttribute("aria-pressed", String(b.dataset.pointer === pointer));
  }
  localPointerGroup.onclick = (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    prefs.set("localPointer", b.dataset.pointer);
    showLocalPointer(b.dataset.pointer);
  };

  for (const el of [canvas, img]) {
    listen(el, "focus", () => document.body.classList.add("controlling"));
    listen(el, "blur", () => document.body.classList.remove("controlling"));
  }

  // Wheel deltas, pixels or lines, in steps of about a notch.
  let wheelY = 0, wheelX = 0;
  function wheelSteps(e) {
    const scale = e.deltaMode === 1 ? 40 : e.deltaMode === 2 ? 800 : 1;
    wheelY += e.deltaY * scale;
    wheelX += e.deltaX * scale;
    const wheel = Math.trunc(wheelY / 50), pan = Math.trunc(wheelX / 50);
    wheelY -= wheel * 50;
    wheelX -= pan * 50;
    return { wheel, pan };
  }

  // Moves go at once, then at most one each MOVE_MS: the last always goes,
  // so the pointer stops where the mouse stopped, and relative steps add up
  // meanwhile. A press or a wheel goes at once and takes a waiting move with it.
  const MOVE_MS = 4;

  function attachInput(el) {
    let dx = 0, dy = 0;
    let lastSent = 0, waiting = null, timer = 0;
    const locked = () => document.pointerLockElement === el;
    const relative = (e, extra) => {
      const x = Math.round(dx), y = Math.round(dy);
      dx -= x;
      dy -= y;
      send({ type: "relative", dx: x, dy: y, buttons: e.buttons, ...extra });
    };
    const sendMove = () => {
      clearTimeout(timer);
      timer = 0;
      const e = waiting;
      waiting = null;
      if (!e) return;
      lastSent = performance.now();
      if (mouseMode !== "relative") mouse(e);
      else if (locked()) relative(e);
    };
    // A press carries the position and the steps so far itself.
    const dropMove = () => { clearTimeout(timer); timer = 0; waiting = null; };
    const resetInput = () => { dropMove(); dx = dy = 0; slots.clear(); };
    inputResets.add(resetInput);
    scope.own(() => inputResets.delete(resetInput));
    listen(el, "mousemove", (e) => {
      if (document.activeElement !== el) return;
      if (mouseMode === "relative") {
        if (!locked()) return;
        dx += e.movementX;
        dy += e.movementY;
      }
      waiting = e;
      if (timer) return;
      const wait = lastSent + MOVE_MS - performance.now();
      if (wait <= 0) sendMove();
      else timer = setTimeout(sendMove, wait);
    });
    listen(el, "mousedown", (e) => {
      el.focus();
      e.preventDefault();
      dropMove();
      if (mouseMode !== "relative") return mouse(e);
      // The first click takes the mouse.
      if (!locked()) return capture.lockPointer();
      relative(e);
    });
    listen(el, "mouseup", (e) => {
      if (document.activeElement !== el) return;
      // The back and forward buttons would leave the page.
      e.preventDefault();
      dropMove();
      if (mouseMode !== "relative") mouse(e);
      else if (locked()) relative(e);
    });
    listen(el, "wheel", (e) => {
      if (document.activeElement !== el) return;
      e.preventDefault();
      const steps = wheelSteps(e);
      if (!steps.wheel && !steps.pan) return;
      dropMove();
      if (mouseMode !== "relative") mouse(e, steps);
      else if (locked()) relative(e, steps);
    }, { passive: false });
    // Touches as the device's touch screen, or the first as the mouse; up to
    // ten, each in a slot of its own while it lasts.
    const slots = new Map();
    const touch = (e) => {
      e.preventDefault();
      el.focus();
      const live = new Set([...e.touches].map((t) => t.identifier));
      for (const id of [...slots.keys()]) if (!live.has(id)) slots.delete(id);
      const used = new Set(slots.values());
      const touches = [];
      for (const t of e.touches) {
        if (!slots.has(t.identifier)) {
          const free = [...Array(10).keys()].find((slot) => !used.has(slot));
          if (free === undefined) continue;
          slots.set(t.identifier, free);
          used.add(free);
        }
        const p = position(t);
        touches.push([slots.get(t.identifier), p.x, p.y]);
      }
      send({ type: "touch", touches });
    };
    for (const type of ["touchstart", "touchmove", "touchend", "touchcancel"]) {
      listen(el, type, touch, { passive: false });
    }
    listen(el, "contextmenu", (e) => e.preventDefault());
    listen(el, "dragstart", (e) => e.preventDefault());
    listen(el, "keydown", (e) => capture.key(e, true));
    listen(el, "keyup", (e) => capture.key(e, false));
    listen(el, "blur", () => capture.releaseKeys());
  }

  // ---- Sound ----
  const workletUrl = (code) => URL.createObjectURL(new Blob([code], { type: "text/javascript" }));

  const soundButton = document.getElementById("sound");
  let sound = null;
  const BYTES = { s16_le: 2, s24_3le: 3, s24_le: 4, s32_le: 4 };

  // Interleaved samples, one Float32Array per channel.
  function decodePcm(buffer, f) {
    const n = f.channels, format = f.sample_format || "s16_le", size = BYTES[format];
    const frames = Math.floor(buffer.byteLength / (size * n));
    const out = Array.from({ length: n }, () => new Float32Array(frames));
    if (format === "s16_le" || format === "s32_le") {
      const pcm = size === 2 ? new Int16Array(buffer, 0, frames * n) : new Int32Array(buffer, 0, frames * n);
      const scale = size === 2 ? 32768 : 2147483648;
      for (let i = 0, k = 0; i < frames; i++) for (let c = 0; c < n; c++) out[c][i] = pcm[k++] / scale;
    } else {
      // 24-bit samples in the low three bytes, sign-extended.
      const bytes = new Uint8Array(buffer);
      for (let i = 0, o = 0; i < frames; i++) {
        for (let c = 0; c < n; c++, o += size) {
          out[c][i] = ((bytes[o] | bytes[o + 1] << 8 | bytes[o + 2] << 16) << 8 >> 8) / 8388608;
        }
      }
    }
    return out;
  }

  // Surround to stereo, in the channel order of USB audio (front left and
  // right, center, LFE, back, side): center, back and side at -3 dB, no LFE.
  const H = Math.SQRT1_2;
  const LAYOUTS = {
    3: [[1, 0], [0, 1], [H, H]],
    4: [[1, 0], [0, 1], [H, 0], [0, H]],
    5: [[1, 0], [0, 1], [H, H], [H, 0], [0, H]],
    6: [[1, 0], [0, 1], [H, H], [0, 0], [H, 0], [0, H]],
    7: [[1, 0], [0, 1], [H, H], [0, 0], [H, 0], [0, H], [0.5, 0.5]],
    8: [[1, 0], [0, 1], [H, H], [0, 0], [H, 0], [0, H], [H, 0], [0, H]],
  };
  function toStereo(channels) {
    const gains = LAYOUTS[channels.length];
    if (!gains) return channels.slice(0, 2);
    const frames = channels[0].length, left = new Float32Array(frames), right = new Float32Array(frames);
    channels.forEach((samples, c) => {
      const [l, r] = gains[c];
      for (let i = 0; i < frames; i++) { left[i] += l * samples[i]; right[i] += r * samples[i]; }
    });
    return [left, right];
  }

  const started = (ctx) =>
    Promise.race([ctx.resume(), new Promise((done) => setTimeout(done, 1000))])
      .then(() => ctx.state === "running");

  async function makePlayer(rate) {
    const ctx = audioContext(rate ? { latencyHint: "interactive", sampleRate: rate }
                                      : { latencyHint: "interactive" });
    const p = { ctx, error: null, onerror: null };
    try {
      if (ctx.audioWorklet) {
        await ctx.audioWorklet.addModule(workletUrl(PLAYER));
        const node = new AudioWorkletNode(ctx, "kuroneko-player",
                                          { numberOfInputs: 0, outputChannelCount: [2] });
        node.onprocessorerror = () => {
          p.error = new Error("Audio playback failed. Turn sound on to retry.");
          p.onerror?.(p.error);
        };
        node.connect(ctx.destination);
        p.deliver = (rate, channels) =>
          node.port.postMessage({ rate, channels }, channels.map((c) => c.buffer));
        p.reset = () => node.port.postMessage("reset");
      } else {
        const queue = new PcmQueue(ctx.sampleRate);
        const node = ctx.createScriptProcessor(2048, 0, 2);
        node.onaudioprocess = (e) =>
          queue.fill([e.outputBuffer.getChannelData(0), e.outputBuffer.getChannelData(1)]);
        node.connect(ctx.destination);
        p.deliver = (rate, channels) => queue.push(rate, channels);
        p.reset = () => queue.reset();
      }
      if (!(await started(ctx)) || p.error) {
        throw p.error || new Error("the browser does not let the sound start");
      }
      return p;
    } catch (error) {
      ctx.close().catch(() => {});
      throw error;
    }
  }

  // At the source's rate the browser resamples for the speakers, better
  // than the queue interpolates.
  async function matchRate(s, rate) {
    if (s.player.ctx.sampleRate === rate || s.failed.has(rate) || s.switching) return;
    s.switching = true;
    try {
      const player = await makePlayer(rate);
      if (sound !== s || player.ctx.sampleRate !== rate) return player.ctx.close();
      watchPlayer(s, player);
      const old = s.player;
      s.player = player;
      old.ctx.close();
    } catch (_) {
      s.failed.add(rate);
    } finally {
      s.switching = false;
    }
  }

  async function startSound() {
    const s = { player: null, ws: null, format: null, failed: new Set(), switching: false };
    sound = s;
    s.player = await makePlayer();
    if (sound !== s) return s.player.ctx.close();
    watchPlayer(s, s.player);
    const open = () => {
      if (sound !== s) return;
      const ws = openSocket(wsUrl("/audio"));
      ws.binaryType = "arraybuffer";
      s.ws = ws;
      ws.onmessage = (ev) => {
        if (typeof ev.data === "string") {
          const message = JSON.parse(ev.data);
          if (!message.format) return;
          s.format = message.format;
          s.player.reset();
          text("sounddetail", `${describe(message.format)} from ${message.format.source.toUpperCase()}`);
          matchRate(s, message.format.rate);
          return;
        }
        if (s.format) s.player.deliver(s.format.rate, toStereo(decodePcm(ev.data, s.format)));
      };
      ws.onclose = () => setTimeout(open, 1000);
    };
    switchOn(soundButton, true);
    text("sounddetail", "Starting…");
    open();
  }

  function stopSound() {
    if (!sound) return;
    const s = sound;
    sound = null;
    if (s.ws) s.ws.close();
    if (s.player) s.player.ctx.close();
    switchOn(soundButton, false);
    text("sounddetail", "In this browser");
  }

  function watchPlayer(s, player) {
    player.onerror = (error) => {
      if (sound !== s || s.player !== player) return;
      stopSound();
      text("sounddetail", error.message);
    };
  }

  soundButton.onclick = async () => {
    if (sound) return stopSound();
    try {
      await startSound();
    } catch (e) {
      stopSound();
      alert(`Sound: ${e.message}`);
    }
  };

  // ---- Microphone: the browser's, as the target's USB microphone ----
  // In the format the device asks for: its rate, channels and sample size,
  // in messages of 20 ms, interpolated from the AudioContext's rate where
  // the two differ.
  const RECORDER = `
    const BYTES = ${JSON.stringify(BYTES)};
    class Recorder extends AudioWorkletProcessor {
      constructor() {
        super();
        this.port.onmessage = ({ data }) => this.configure(data);
      }
      configure(f) {
        this.f = f;
        this.n = f.channels;
        this.size = BYTES[f.sample_format];
        this.step = sampleRate / f.rate;
        this.t = 0;
        this.prev = new Float32Array(this.n);
        this.cur = new Float32Array(this.n);
        this.frames = Math.max(1, Math.round(f.rate / 50));
        this.begin();
      }
      begin() {
        this.out = new ArrayBuffer(this.frames * this.n * this.size);
        this.view = new DataView(this.out);
        this.o = 0;
      }
      put(v) {
        const view = this.view, o = this.o;
        if (this.size === 2) {
          view.setInt16(o, Math.max(-32768, Math.min(32767, Math.round(v * 32768))), true);
        } else if (this.f.sample_format === "s32_le") {
          view.setInt32(o, Math.max(-2147483648, Math.min(2147483647, Math.round(v * 2147483648))), true);
        } else {
          const x = Math.max(-8388608, Math.min(8388607, Math.round(v * 8388608)));
          view.setUint8(o, x & 255);
          view.setUint8(o + 1, (x >> 8) & 255);
          view.setUint8(o + 2, (x >> 16) & 255);
          if (this.size === 4) view.setUint8(o + 3, x < 0 ? 255 : 0);
        }
        this.o += this.size;
        if (this.o === this.out.byteLength) {
          this.port.postMessage(this.out, [this.out]);
          this.begin();
        }
      }
      process(inputs) {
        const input = inputs[0];
        if (!this.f || !input || !input.length) return true;
        const k = input.length, n = this.n, cur = this.cur, prev = this.prev;
        for (let i = 0; i < input[0].length; i++) {
          // The browser's channels onto the device's: a mono microphone on
          // both sides, a stereo one averaged for mono.
          if (n === 1) {
            let sum = 0;
            for (const channel of input) sum += channel[i];
            cur[0] = sum / k;
          } else {
            for (let c = 0; c < n; c++) cur[c] = c < 2 ? input[Math.min(c, k - 1)][i] : 0;
          }
          for (; this.t < 1; this.t += this.step) {
            for (let c = 0; c < n; c++) this.put(prev[c] + (cur[c] - prev[c]) * this.t);
          }
          this.t -= 1;
          prev.set(cur);
        }
        return true;
      }
    }
    registerProcessor("kuroneko-recorder", Recorder);`;

  const micButton = document.getElementById("mic");
  const usbaudio = document.getElementById("usbaudio");
  let audioMode = "off";
  let mic = null;

  const prefs = {
    get(key, fallback) {
      try { const v = localStorage.getItem(key); return v === null ? fallback : JSON.parse(v); }
      catch (_) { return fallback; }
    },
    set(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch (_) {} },
  };

  async function startMic() {
    // Made in the click, before the permission prompt ends the user gesture.
    const m = { stream: null, ctx: audioContext(), node: null, ws: null, limit: 0 };
    mic = m;
    const voice = prefs.get("voice", true);
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: { ideal: 2 }, echoCancellation: voice, noiseSuppression: voice,
               autoGainControl: voice },
    });
    m.stream = stream;
    scope.own(() => stream.getTracks().forEach((track) => track.stop()));
    if (!scope.active || mic !== m) return stream.getTracks().forEach((track) => track.stop());
    await started(m.ctx);
    if (!scope.active || mic !== m) return;
    const ws = openSocket(wsUrl("/microphone"));
    ws.binaryType = "arraybuffer";
    m.ws = ws;
    ws.onmessage = (ev) => {
      if (typeof ev.data !== "string") return;
      const message = JSON.parse(ev.data);
      if (!message.format) return;
      useFormat(m, message.format).catch((e) => {
        if (mic !== m) return;
        stopMic();
        alert(`Microphone: ${e.message}`);
      });
    };
    ws.onclose = (e) => {
      if (mic !== m) return;
      stopMic();
      if (e.reason) alert(`Microphone: ${e.reason}`);
    };
    switchOn(micButton, true);
  }

  // The first format builds the recording, in an AudioContext at the
  // device's rate where the browser resamples the microphone itself; later
  // ones, when the target chooses another rate, go to the recorder.
  async function useFormat(m, f) {
    // A slow network drops samples rather than delay them past 100 ms.
    m.limit = (f.rate * f.channels * BYTES[f.sample_format]) / 10;
    if (!m.node) {
      let ctx = null;
      try {
        ctx = audioContext({ sampleRate: f.rate });
        await record(m, ctx);
        m.ctx.close();
        m.ctx = ctx;
      } catch (_) {
        if (ctx) ctx.close();
        await record(m, m.ctx);
      }
    }
    m.node.port.postMessage(f);
    text("micdetail", `The target hears ${describe(f)}`);
  }

  async function record(m, ctx) {
    await ctx.audioWorklet.addModule(workletUrl(RECORDER));
    const source = ctx.createMediaStreamSource(m.stream);
    const node = new AudioWorkletNode(ctx, "kuroneko-recorder");
    // Through a muted gain to the output, so that every browser runs it.
    const mute = ctx.createGain();
    mute.gain.value = 0;
    source.connect(node).connect(mute).connect(ctx.destination);
    node.port.onmessage = ({ data }) => {
      if (m.ws.readyState === WebSocket.OPEN && m.ws.bufferedAmount < m.limit) m.ws.send(data);
    };
    if (!(await started(ctx))) throw new Error("the browser does not let the microphone start");
    m.node = node;
  }

  function stopMic() {
    if (!mic) return;
    const m = mic;
    mic = null;
    if (m.stream) m.stream.getTracks().forEach((track) => track.stop());
    if (m.ws) m.ws.close();
    m.ctx.close();
    switchOn(micButton, false);
  }

  function updateMicButton() {
    const usable = audioMode !== "off";
    micButton.disabled = !usable && !mic;
    micButton.title = !usable ? "Turn the USB microphone on first"
      : window.isSecureContext ? "Talk into the target's USB microphone"
      : "The microphone needs the HTTPS page";
    if (!mic) text("micdetail", micButton.title);
  }

  micButton.onclick = async () => {
    if (mic) return stopMic();
    if (!window.isSecureContext) {
      if (confirm("Browsers give the microphone only to secure pages. Open the HTTPS page?")) {
        location.href = `https://${location.hostname}/`;
      }
      return;
    }
    try {
      await startMic();
    } catch (e) {
      stopMic();
      alert(`Microphone: ${e.message}`);
    }
  };

  function showAudioMode(mode) {
    if (!mode || usbaudio.disabled) return;
    audioMode = mode;
    usbaudio.value = mode;
    if (mode === "off") stopMic();
    updateMicButton();
  }

  // ---- USB devices ----
  const kHz = (rate) => `${+(rate / 1000).toFixed(3)} kHz`;
  const CHANNEL_NAMES = { 1: "mono", 2: "stereo", 6: "5.1", 8: "7.1" };
  function describe(f) {
    const bits = { s16_le: 16, s24_3le: 24, s24_le: 24, s32_le: 32 }[f.sample_format] || 16;
    return `${kHz(f.rate)} ${CHANNEL_NAMES[f.channels] || `${f.channels} channels`} ${bits}-bit`;
  }
  const USB_ERRORS = {
    not_enough_endpoints: (_d, body) => `These take ${body.need.in} IN and ${body.need.out} OUT endpoints; ` +
      `the NanoKVM has ${body.have.in} and ${body.have.out}. Turn something off under USB on the device page.`,
  };

  async function postUsb(changes) {
    const reply = await fetch("/api/usb", { method: "POST",
      headers: { "content-type": "application/json" }, body: JSON.stringify(changes) });
    const body = await reply.json().catch(() => ({}));
    if (!reply.ok) {
      const explain = USB_ERRORS[body.error];
      throw new Error(explain ? explain(body.direction, body) : body.error || `HTTP ${reply.status}`);
    }
    return body;
  }

  usbaudio.onchange = async () => {
    const mode = usbaudio.value;
    usbaudio.disabled = true;
    try {
      audioMode = (await postUsb({ audio: mode })).settings.audio;
    } catch (e) {
      alert(`USB audio: ${e.message}`);
    } finally {
      usbaudio.disabled = false;
      showAudioMode(audioMode);
    }
  };


  // The browser's own processing of the microphone, kept in this browser.
  const voiceSwitch = document.getElementById("voice");
  const showVoice = () => voiceSwitch.setAttribute("aria-checked", String(prefs.get("voice", true)));
  voiceSwitch.onclick = () => { prefs.set("voice", !prefs.get("voice", true)); showVoice(); };
  showVoice();

  // Keys the browser does not let the page take, and typed text.
  function runAction(value) {
    if (value === "type") {
      const typed = prompt("Text to type on the target, as a US keyboard would:");
      if (typed) send({ type: "text", text: typed });
    } else if (value) {
      capture.releaseKeys();
      const codes = value.split("+");
      for (const code of codes) send({ type: "key", code, down: true });
      for (const code of codes.reverse()) send({ type: "key", code, down: false });
    }
    view.focus();
  }

  // The menu's log out and password: they change the session's cookie,
  // which only a request can.
  const postJson = (path, body) => fetch(path, { method: "POST",
    headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  listen(window, "kvm:logout", async () => {
    await postJson("/api/auth/logout", {}).catch(() => null);
    location.reload();
  });
  listen(window, "kvm:password", async (e) => {
    const form = e.target, state = form.querySelector(".message");
    const { current, password, again } = Object.fromEntries(new FormData(form));
    state.classList.toggle("error", false);
    if (password !== again) {
      state.classList.add("error");
      state.textContent = "The two new passwords differ.";
      return;
    }
    const reply = await postJson("/api/auth/password", { current, password }).catch(() => null);
    const body = reply ? await reply.json().catch(() => ({})) : {};
    state.classList.toggle("error", !(reply && reply.ok));
    state.textContent = reply && reply.ok ? "Password changed. Other sessions have ended."
      : `Not changed: ${body.error || (reply ? `HTTP ${reply.status}` : "no answer")}`;
    if (reply && reply.ok) form.reset();
  });
  for (const b of document.querySelectorAll("[data-keys], [data-action]")) {
    b.onclick = () => { closePop(); runAction(b.dataset.keys || b.dataset.action); };
  }

  // ---- The video stream's quality: a preset, or the device page's own settings ----
  const quality = document.getElementById("quality");
  const presetText = (p) => p.rate_control === "vbr" ? `${p.label} quality`
    : `${p.label}, ${p.bitrate / 1e6} Mbit/s`;
  function showQuality(video) {
    quality.replaceChildren(...video.presets.map((p) => new Option(presetText(p), p.name)));
    if (video.preset === "custom") quality.add(new Option("Custom quality", "custom"));
    quality.value = video.preset;
  }
  async function loadQuality() {
    try {
      const reply = await fetch("/api/video");
      if (reply.ok) showQuality(await reply.json());
    } catch (_) {}
  }
  quality.onchange = async () => {
    if (quality.value === "custom") return openDevice("video");
    quality.disabled = true;
    try {
      const reply = await fetch("/api/video", { method: "POST",
        headers: { "content-type": "application/json" }, body: JSON.stringify({ preset: quality.value }) });
      if (!reply.ok) throw new Error(`HTTP ${reply.status}`);
      showQuality(await reply.json());
    } catch (e) {
      alert(`Quality: ${e.message}`);
      loadQuality();
    } finally {
      quality.disabled = false;
      view.focus();
    }
  };
  listen(document, "visibilitychange", () => { if (!document.hidden) loadQuality(); });

  // ---- Virtual disk ----
  document.getElementById("disk").onclick = () => KuronekoDisk.open({ onClose: () => view.focus() });

  // ---- Text in the picture: drag over a part of it, the NanoKVM's NPU reads it ----
  const ocrButton = document.getElementById("ocr");
  const ocrLayer = document.getElementById("ocrlayer");
  const ocrBox = document.getElementById("ocrbox");
  const ocrDialog = document.getElementById("ocrdialog");
  const ocrText = document.getElementById("ocrtext");
  const ocrState = document.getElementById("ocrstate");
  let ocrStart = null;

  function ocrSelecting(on) {
    ocrLayer.hidden = !on;
    ocrBox.hidden = true;
    ocrButton.classList.toggle("on", on);
    ocrStart = null;
    if (!on) view.focus();
  }
  ocrButton.onclick = () => ocrSelecting(ocrLayer.hidden);
  listen(document, "keydown", (e) => {
    if (e.key === "Escape" && !ocrLayer.hidden) { e.preventDefault(); ocrSelecting(false); }
  }, true);

  const ocrRect = (a, b) => ({ left: Math.min(a.clientX, b.clientX), top: Math.min(a.clientY, b.clientY),
    width: Math.abs(a.clientX - b.clientX), height: Math.abs(a.clientY - b.clientY) });
  ocrLayer.onpointerdown = (e) => {
    ocrStart = { clientX: e.clientX, clientY: e.clientY };
    ocrLayer.setPointerCapture(e.pointerId);
  };
  ocrLayer.onpointermove = (e) => {
    if (!ocrStart) return;
    const r = ocrRect(ocrStart, e);
    Object.assign(ocrBox.style, { left: `${r.left}px`, top: `${r.top}px`,
      width: `${r.width}px`, height: `${r.height}px` });
    ocrBox.hidden = false;
  };
  ocrLayer.onpointerup = async (e) => {
    if (!ocrStart) return;
    const a = position(ocrStart), b = position(e);
    ocrSelecting(false);
    const area = { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y),
                   width: Math.abs(a.x - b.x), height: Math.abs(a.y - b.y) };
    if (area.width < 0.002 || area.height < 0.002) return;
    ocrText.value = "";
    ocrState.textContent = "Reading…";
    ocrDialog.showModal();
    try {
      const reply = await fetch("/api/ocr", { method: "POST",
        headers: { "content-type": "application/json" }, body: JSON.stringify(area) });
      const body = await reply.json().catch(() => ({}));
      if (!reply.ok) {
        ocrState.textContent = body.error || `failed (${reply.status})`;
        return;
      }
      ocrText.value = body.text;
      ocrState.textContent = body.lines.length ? `${body.lines.length} line(s)` : "No text found here.";
    } catch (err) {
      ocrState.textContent = String(err);
    }
  };
  document.getElementById("ocrcopy").onclick = async () => {
    try {
      await navigator.clipboard.writeText(ocrText.value);
      ocrState.textContent = "Copied.";
    } catch (_) {
      ocrText.select();
      ocrState.textContent = "Select and copy: the browser keeps the clipboard from plain HTTP pages.";
    }
  };
  document.getElementById("ocrtype").onclick = () => {
    if (ocrText.value) send({ type: "text", text: ocrText.value });
    ocrDialog.close();
  };
  document.getElementById("ocrclose").onclick = () => ocrDialog.close();
  listen(ocrDialog, "close", () => view.focus());

  updateMicButton();
  playback = prefs.get("playback", "latency") === "smooth" ? "smooth" : "latency";
  showPlayback();
  const statsAt = prefs.get("statsAt", null);
  if (statsAt && Number.isFinite(statsAt.x) && Number.isFinite(statsAt.y)) {
    statsBox.style.left = `${statsAt.x}px`;
    statsBox.style.top = `${statsAt.y}px`;
  }
  showStats(prefs.get("stats", false) === true);
  mouseMode = prefs.get("mouseMode", "absolute") === "relative" ? "relative" : "absolute";
  showMouseMode();
  const localPointer = prefs.get("localPointer", "dot");
  showLocalPointer(["dot", "arrow", "none"].includes(localPointer) ? localPointer : "dot");

  start();
}

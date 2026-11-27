// Samples waiting to be played, at the AudioContext's rate, interpolated
// from the source's. The AudioWorklet runs it on the audio thread; pages
// without a secure context have no AudioWorklet and run it in a
// ScriptProcessor.
export class PcmQueue {
  constructor(rate) { this.rate = rate; this.sourceRate = rate; this.step = 1; this.reset(); }
  reset() { this.chunks = []; this.index = 0; this.frac = 0; this.queued = 0; this.playing = false; }
  push(rate, channels) {
    if (rate !== this.sourceRate) {
      this.reset();
      this.sourceRate = rate;
      this.step = rate / this.rate;
    }
    this.chunks.push(channels);
    this.queued += channels[0].length;
    // More than 300 ms behind: drop the oldest, so the sound never lags.
    while (this.queued > this.sourceRate * 0.3 && this.chunks.length > 1) {
      this.queued -= this.chunks.shift()[0].length - this.index;
      this.index = 0;
    }
  }
  fill(out) {
    // After running dry, wait for 60 ms of samples.
    if (!this.playing && this.queued < this.sourceRate * 0.06) {
      for (const o of out) o.fill(0);
      return;
    }
    this.playing = true;
    for (let i = 0; i < out[0].length; i++) {
      const cur = this.chunks[0];
      if (!cur) {
        for (const o of out) o[i] = 0;
        this.playing = false;
        continue;
      }
      let next = cur, j = this.index + 1;
      if (j >= cur[0].length) {
        if (this.chunks.length > 1) { next = this.chunks[1]; j = 0; } else j = this.index;
      }
      for (let c = 0; c < out.length; c++) {
        const a = cur[Math.min(c, cur.length - 1)][this.index];
        const b = next[Math.min(c, next.length - 1)][j];
        out[c][i] = a + (b - a) * this.frac;
      }
      this.frac += this.step;
      while (this.frac >= 1 && this.chunks.length) {
        this.frac -= 1;
        this.queued--;
        if (++this.index >= this.chunks[0][0].length) { this.chunks.shift(); this.index = 0; }
      }
    }
  }
}

// The bundler may rename or anonymize the class; bind the worklet's own name.
export const PLAYER = `const PcmQueue = ${PcmQueue.toString()};
  class Player extends AudioWorkletProcessor {
    constructor() {
      super();
      this.queue = new PcmQueue(sampleRate);
      this.port.onmessage = ({ data }) =>
        data === "reset" ? this.queue.reset() : this.queue.push(data.rate, data.channels);
    }
    process(_inputs, outputs) { this.queue.fill(outputs[0]); return true; }
  }
  registerProcessor("kuroneko-player", Player);`;


import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const root = fileURLToPath(new URL("../../", import.meta.url));
const bundle = execFileSync(`${root}_build/esbuild-${process.platform}-${process.arch}`,
  ["assets/js/audio-playback.mjs", "--bundle", "--minify", "--target=es2022", "--format=cjs"],
  { cwd: root, encoding: "utf8" });
const compiled = { module: { exports: {} } };
vm.runInNewContext(bundle, compiled);

function processor() {
  let Player;
  vm.runInNewContext(compiled.module.exports.PLAYER, {
    sampleRate: 48000,
    AudioWorkletProcessor: class { constructor() { this.port = {}; } },
    registerProcessor(name, type) { assert.equal(name, "kuroneko-player"); Player = type; },
  });
  return new Player();
}

test("production minification preserves the worklet queue and stereo playback", () => {
  const player = processor();
  const left = Float32Array.from({ length: 3840 }, (_, i) => Math.sin(i / 12) * 0.25);
  const right = Float32Array.from(left, (x) => -x);
  player.port.onmessage({ data: { rate: 48000, channels: [left, right] } });
  const out = [new Float32Array(128), new Float32Array(128)];
  assert.equal(player.process([], [out]), true);
  assert.deepEqual(out[0], left.slice(0, 128));
  assert.deepEqual(out[1], right.slice(0, 128));
});

test("the production worklet drops queued sound when its source resets", () => {
  const player = processor();
  player.port.onmessage({ data: { rate: 44100, channels: [new Float32Array(4410).fill(0.5)] } });
  player.port.onmessage({ data: "reset" });
  const out = [new Float32Array(128).fill(1), new Float32Array(128).fill(1)];
  player.process([], [out]);
  assert.ok(out.every((channel) => channel.every((x) => x === 0)));
});

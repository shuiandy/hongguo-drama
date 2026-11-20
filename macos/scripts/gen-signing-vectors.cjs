// SPDX-License-Identifier: GPL-3.0-only
// Regenerates Tests/HongguoCoreTests/Fixtures/app-signing-vectors.json from the Electron
// reference implementations in src/native with fixed time and randomness. Synthetic ids only.
//   node macos/scripts/gen-signing-vectors.cjs > HongguoKit/Tests/HongguoCoreTests/Fixtures/app-signing-vectors.json
'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const crypto = require('node:crypto');
const { gzipSync } = require('node:zlib');
const { createRequire } = require('node:module');
const native = require('./upstream-native.cjs');

function load(file, randomQueue, now, extra = '') {
  const filename = path.join(native, file);
  const realRequire = createRequire(filename);
  const queue = randomQueue.map(hex => Buffer.from(hex, 'hex'));
  class FixedDate extends Date { static now() { return now; } }
  const module = { exports: {} };
  const context = { module, exports: module.exports, Buffer, URL, Date: FixedDate, Math, BigInt,
    require(name) {
      if (name === 'node:crypto') return { ...crypto, randomBytes(n) {
        const next = queue.shift();
        if (!next || next.length !== n) throw new Error(`unexpected randomBytes(${n})`);
        return next;
      } };
      return realRequire(name);
    } };
  vm.runInNewContext(fs.readFileSync(filename, 'utf8') + extra, context, { filename });
  module.exports.__remaining = () => queue.length;
  return module.exports;
}

const NONCE = '0102030405060708090a0b0c0d0e0f101112';
const synthetic = { aid: '8662', app_name: 'novelread', version_code: '74332', version_name: '7.4.3.32',
  channel: 'vivo_8662_64', device_platform: 'android', device_type: 'PGT-AN10', os_version: '12',
  update_version_code: '74332', iid: '2234567890123456789', cdid: '00000000-0000-4000-8000-000000000003',
  device_id: '1234567890123456789' };
const v5 = [];
for (const [index, now] of [1800000000000, 1763430000123, 1763430001999].entries()) {
  const payload = JSON.stringify({ mixed_video_id_map: { '1004': [String(7000000000000000000n + BigInt(index))] }, dr_scene: 'player' });
  const body = gzipSync(Buffer.from(payload));
  const randoms = [NONCE, '11223344', '55667788', '99aabbcc', 'ddeeff00'].map((v, i) => i === 0 ? v : crypto.createHash('md5').update(`${index}:${v}`).digest('hex').slice(0, 8));
  const values = index === 2 ? { ...synthetic, text: '中文 !*\'()~ +&=%', ts: '0' } : synthetic;
  const mod = load('playback-v5.js', randoms, now);
  const signed = mod.signPlaybackV5({ base: 'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/player/v1', values, body, now });
  if (mod.__remaining()) throw new Error('unused random values');
  v5.push({ now, values: Object.entries(values), body: body.toString('hex'), processNonce: Buffer.from(NONCE, 'hex').toString('base64url'),
    processStarted: now, random32: randoms.slice(1).map(h => Buffer.from(h, 'hex').readUInt32LE()), url: signed.url, headers: signed.headers });
}

const player = [];
const sig = load('playback-signature.js', [], 0);
for (const [index, ts] of [1800000000, 1763430000].entries()) {
  const query = `ac=wifi&aid=8662&device_id=1234567890123456789&version_name=7.4.3.32&ts=${ts}&_rticket=${ts}123`;
  const body = index === 0 ? gzipSync(Buffer.from('{"dr_scene":"player"}')) : null;
  const randField = index === 0 ? -123456789 : 987654321;
  const ladonRandom = Buffer.from(index === 0 ? 'a1b2c3d4' : '00ff10ee', 'hex');
  const headers = sig.signPlayer({ query, body, ts, randField, ladonRandom });
  player.push({ query, body: body ? body.toString('hex') : null, ts, randField, ladonRandom: ladonRandom.toString('hex'), headers });
}

const sm3 = require(path.join(native, 'sm3.js'));
const sm3Vectors = ['', 'abc', 'abcd'.repeat(16), '红果短剧'].map(text => ({ input: Buffer.from(text).toString('hex'), digest: sm3(Buffer.from(text)).toString('hex') }));

// deriveContentKey / decryptSpadeUrl are module-private in app-source.js; expose them in the VM.
const app = load('app-source.js', [Buffer.alloc(18, 9).toString('hex'), Buffer.alloc(6, 7).toString('hex'), Buffer.alloc(6, 8).toString('hex')], 0,
  '\nmodule.exports.__test = { deriveContentKey, decryptSpadeUrl, checkedUrl };');
function encodedKey(hex) { // from scripts/check-source-recovery.cjs
  const plain = Buffer.from(`0${hex}`), raw = Buffer.alloc(34), previous = [246, 85];
  for (let i = 0; i < plain.length; i++) {
    raw[i + 1] = ((plain[i] + 21 + (i.toString(2).split('1').length - 1)) & 255) ^ previous[i & 1];
    previous[i & 1] = raw[i + 1];
  }
  raw[0] = 48 ^ raw[1] ^ raw[2];
  return raw.toString('base64');
}
const contentKeys = ['00112233445566778899aabbccddeeff', '0f1e2d3c4b5a69788796a5b4c3d2e1f0'].map(hex => {
  const spade = encodedKey(hex);
  return { spade, key: app.__test.deriveContentKey(spade).toString('hex') };
});
function encryptSpade(url, seed) {
  const constants = Buffer.from('4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58', 'hex');
  const h2 = crypto.createHash('sha512').update(Buffer.concat([crypto.createHash('sha512').update(seed).digest(), constants])).digest();
  const cipher = crypto.createCipheriv('aes-128-cbc', h2.subarray(0, 16), h2.subarray(16, 32));
  return Buffer.concat([Buffer.from([0xa8, 0x00, 0x01, 0x00]), cipher.update(url), cipher.final()]).toString('base64');
}
const seed = Buffer.from('synthetic-key-seed-0001');
const spadeUrls = ['https://v3-reading-video.qznovelvod.com/synthetic/abc.mp4?a=1&b=2'].map(url => {
  const cipher = encryptSpade(url, seed);
  return { cipher, seed: seed.toString('base64'), url: app.__test.decryptSpadeUrl(cipher, seed) };
});
process.stdout.write(JSON.stringify({ v5, player, sm3: sm3Vectors, contentKeys, spadeUrls }, null, 1) + '\n');

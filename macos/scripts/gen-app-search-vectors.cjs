// SPDX-License-Identifier: GPL-3.0-only
// Regenerates Tests/HongguoCoreTests/Fixtures/app-search-signing-vectors.json from the Electron
// reference src/native/app-source.js (signedSearchRequest / signedMetadataRequest) with fixed time,
// process nonce and random values. Synthetic ids only.
//   node macos/scripts/gen-app-search-vectors.cjs > macos/Tests/HongguoCoreTests/Fixtures/app-search-signing-vectors.json
'use strict';
const path = require('node:path');
const crypto = require('node:crypto');

const PROCESS_NONCE_HEX = '000102030405060708090a0b0c0d0e0f1011';
const PROCESS_STARTED = 1763430000000;
let clock = PROCESS_STARTED;
const realNow = Date.now;
Date.now = () => clock;
const realRandomBytes = crypto.randomBytes;
let firstRandomBytes = true;
crypto.randomBytes = (n, ...rest) => {
  if (firstRandomBytes && n === 18) { firstRandomBytes = false; return Buffer.from(PROCESS_NONCE_HEX, 'hex'); }
  return Buffer.alloc(n, 0x11);
};
const Module = require('node:module');
const originalLoad = Module._load;
Module._load = function (request, ...rest) {
  if (request === 'axios') return {};
  return originalLoad.call(this, request, ...rest);
};
const app = require(path.join(__dirname, '../../src/native/app-source.js'));

let queue = [];
const realRandom = Math.random;
Math.random = () => {
  if (!queue.length) throw new Error('random queue empty');
  return queue.shift() / 0x100000000;
};

const identity = { device_id: '1234567890123456789', iid: '2234567890123456789', cdid: '01234567-89ab-cdef-0123-456789abcdef' };
const randoms = [[0x12345678, 0x9abcdef0, 0x0fedcba9, 0x87654321, 0xdeadbeef, 0x00c0ffee, 0x7fffffff],
                 [0xffffffff, 0x00000000, 0x80000000, 0x13579bdf, 0x2468ace0, 0xfedcba98, 0x01020304]];
const search = [
  { now: 1763430001234, keyword: '霸总', page: 1, cursor: null, randoms: randoms[0] },
  { now: 1800000000999, keyword: 'a b&c!', page: 2, cursor: { search_id: 's1', passback: 'p=1', next_offset: 20 }, randoms: randoms[1] },
].map(item => {
  clock = item.now; queue = item.randoms.slice();
  const signed = app.signedSearchRequest({ keyword: item.keyword, page: item.page, cursor: item.cursor, identity });
  return { ...item, url: signed.url, headers: signed.headers, used: item.randoms.length - queue.length };
});
// The metadata device ids are random per process: export them so Swift can use the same.
const metadata = [
  { now: 1763430002000, apiPath: '/reading/distribution/category/landpage/v/', values: { offset: '0', limit: '50', genre: 'short_play' }, payload: null, randoms: randoms[0] },
  { now: 1763430003000, apiPath: '/reading/bookapi/bookmall/cell/change/v', values: { a: '1' }, payload: { cell_id: '7' }, randoms: randoms[1] },
].map(item => {
  clock = item.now; queue = item.randoms.slice();
  const signed = app.signedMetadataRequest(item.apiPath, item.values, item.payload);
  return { ...item, url: signed.url, headers: signed.headers, body: signed.body ? signed.body.toString('utf8') : null,
    used: item.randoms.length - queue.length };
});
Date.now = realNow; Math.random = realRandom; crypto.randomBytes = realRandomBytes;
process.stdout.write(JSON.stringify({ processNonceHex: PROCESS_NONCE_HEX, processStarted: PROCESS_STARTED, identity, search, metadata }, null, 2) + '\n');

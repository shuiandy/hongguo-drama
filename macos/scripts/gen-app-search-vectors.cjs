// SPDX-License-Identifier: GPL-3.0-only
// Regenerates Tests/HongguoCoreTests/Fixtures/app-search-signing-vectors.json from the Electron
// reference src/native/app-source.js (signedSearchRequest / signedMetadataRequest) with fixed time,
// process nonce and random values. Synthetic ids only. The account write vectors (signed JSON POST to
// read_history/update and read_progress/upload) have no Electron caller, so they are composed here from
// the same app-source.js primitives (branchOf, xGorgon, helios, buildMedusa), exposed only to this script.
//   node macos/scripts/gen-app-search-vectors.cjs > macos/Tests/HongguoCoreTests/Fixtures/app-search-signing-vectors.json
'use strict';
const path = require('node:path');
const fs = require('node:fs');
const crypto = require('node:crypto');

const PROCESS_NONCE_HEX = '000102030405060708090a0b0c0d0e0f1011';
const PROCESS_STARTED = 1763430000000;
let clock = PROCESS_STARTED;
const realNow = Date.now;
Date.now = () => clock;
const realRandomBytes = crypto.randomBytes;
// Every 18-byte draw (app-source.js PROCESS_NONCE, and any other module loaded first) gets the
// fixed nonce; everything else (the catalogue device ids) a constant fill.
crypto.randomBytes = (n, ...rest) => n === 18 ? Buffer.from(PROCESS_NONCE_HEX, 'hex') : Buffer.alloc(n, 0x11);
const Module = require('node:module');
const originalLoad = Module._load;
Module._load = function (request, ...rest) {
  if (request === 'axios') return {};
  return originalLoad.call(this, request, ...rest);
};
const appFile = path.join(__dirname, '../../src/native/app-source.js');
const appModule = new Module(appFile, module);
appModule.filename = appFile;
appModule.paths = Module._nodeModulePaths(path.dirname(appFile));
appModule._compile(fs.readFileSync(appFile, 'utf8') +
  '\nmodule.exports.__internals = { xGorgon, buildMedusa, helios, branchOf, pythonUrlEncode, md5, be32, le32, DEVICE, SEARCH_UA };\n', appFile);
const app = appModule.exports;

// Reference for AppLegacySigner.accountWrite (7.3.9.32 profile, hash branch 0, body bound by x-ss-stub).
function signedAccountWrite(apiPath, body, identity) {
  const t = app.__internals;
  const device = { ...t.DEVICE, version_code: '73932', version_name: '7.3.9.32', manifest_version_code: '73932',
    update_version_code: '73932', pv_player: '73932', iid: identity.iid, device_id: identity.device_id, cdid: identity.cdid };
  const khronos = Math.floor(Date.now() / 1000), ticketBase = Date.now();
  let query, url, requestTicket;
  for (let n = 0; n < 128; n += 1) {
    requestTicket = ticketBase + n;
    query = t.pythonUrlEncode({ ...device, ts: String(khronos), _rticket: String(requestTicket) });
    url = `https://api5-normal-sinfonlinea.fqnovel.com${apiPath}?${query}`;
    if (t.branchOf(url, body, khronos) === 0) break;
    if (n === 127) throw new Error('no branch 0');
  }
  const headers = {
    'User-Agent': t.SEARCH_UA.replace('72232', '73932'), Accept: 'application/json; charset=utf-8,application/x-protobuf',
    'Content-Type': 'application/json; charset=utf-8', 'x-ss-stub': t.md5(body),
    'x-ss-req-ticket': String(requestTicket), 'x-tt-request-tag': 't=0;n=0', 'sdk-version': '2',
    'passport-sdk-version': '50561', 'x-xs-from-web': '0', 'x-khronos': String(khronos),
    'x-ladon': t.be32(khronos).toString('base64'), 'x-argus': t.le32(khronos).toString('base64'),
    'x-gorgon': t.xGorgon(query, body, khronos, Math.floor(Math.random() * 65536)),
    'x-helios': t.helios(khronos), 'x-medusa': t.buildMedusa(url, body, khronos, device), 'x-tt-dt': '',
  };
  return { url, headers };
}

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
const account = [
  { now: 1763430004000, apiPath: '/reading/bookapi/read_history/list/v1/',
    values: { book_type: '2', limit: '0', offset: '0', last_min_read_timestamp_ms: '0', full_field: 'true', is_first_load: 'true', query_soft_deleted: 'false' },
    randoms: randoms[0] },
  { now: 1763430005000, apiPath: '/reading/user/info/v1/', values: {}, randoms: randoms[1] },
].map(item => {
  clock = item.now; queue = item.randoms.slice();
  const signed = app.signedAccountRequest(item.apiPath, item.values, identity);
  return { ...item, valueOrder: Object.keys(item.values), url: signed.url, headers: signed.headers, used: item.randoms.length - queue.length };
});
const accountWrite = [
  { now: 1763430006000, apiPath: '/reading/bookapi/read_history/update/v1/',
    body: '{"update_datas":[{"book_id":7664958856774044697,"book_id_str":"7664958856774044697","book_type":2,"vid":7664960983332310041,"vid_index":3}]}',
    randoms: randoms[0] },
  { now: 1763430007000, apiPath: '/reading/bookapi/read_progress/upload/v1/',
    body: '{"books":[{"book_id":"7664958856774044697","item_id":"7664960983332310041","vid_index":3,"current_play_time":12000}],"write_mode":1}',
    randoms: randoms[1] },
].map(item => {
  clock = item.now; queue = item.randoms.slice();
  const signed = signedAccountWrite(item.apiPath, Buffer.from(item.body), identity);
  return { ...item, url: signed.url, headers: signed.headers, used: item.randoms.length - queue.length };
});
Date.now = realNow; Math.random = realRandom; crypto.randomBytes = realRandomBytes;
process.stdout.write(JSON.stringify({ processNonceHex: PROCESS_NONCE_HEX, processStarted: PROCESS_STARTED, identity, search, metadata, account, accountWrite }, null, 2) + '\n');

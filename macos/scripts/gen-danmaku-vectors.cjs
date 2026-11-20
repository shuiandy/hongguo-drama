// SPDX-License-Identifier: GPL-3.0-only
// Regenerates Tests/HongguoCoreTests/Fixtures/danmaku-signing-vectors.json from the Electron
// reference src/native/danmaku-sign.js with fixed time, ids and nonces. Synthetic ids only.
//   node macos/scripts/gen-danmaku-vectors.cjs > macos/Tests/HongguoCoreTests/Fixtures/danmaku-signing-vectors.json
'use strict';
const path = require('node:path');
const upstreamNative = require('./upstream-native.cjs');
const sign = require(path.join(upstreamNative, 'danmaku-sign.js'));

const cases = [
  { stampMs: 1763430000123, deviceId: '1234567890123456789', installId: '2234567890123456789', nonce: '0102030405060708090a0b' },
  { stampMs: 1800000000999, deviceId: '1000000000000000001', installId: '8999999999999999999', nonce: 'ffeeddccbbaa99887766f0' },
  { stampMs: 1700000000000, deviceId: '5555555555555555555', installId: '6666666666666666666', nonce: '00000000000000000000ff' },
].map(item => {
  const rawQuery = sign.buildQuery(item);
  const stamp = Math.floor(item.stampMs / 1000);
  const nonce = Buffer.from(item.nonce, 'hex');
  return { ...item, stamp, rawQuery, headers: sign.signCommentHeaders({ rawQuery, stamp, nonce }) };
});

const deviceIds = ['0000000000000000', 'ffffffffffffffff', '0123456789abcdef'].map(hex => ({
  random: hex, deviceId: sign.newDeviceId(() => Buffer.from(hex, 'hex')),
}));
const uvarint = [0, 1, 127, 128, 300, 16384, 1388734, 135135744].map(n => ({ value: n, hex: sign.uvarint(BigInt(n)).toString('hex') }));

// danmaku.js needs axios only for live requests; parsing is pure, so a stub is enough here.
const Module = require('node:module');
const originalLoad = Module._load;
Module._load = function (request, ...rest) {
  if (request === 'axios') return { post() { throw new Error('offline'); } };
  return originalLoad.call(this, request, ...rest);
};
const danmaku = require(path.join(upstreamNative, 'danmaku.js'));
Module._load = originalLoad;

const VID = '7300000000000000001';
const row = (text, extra = {}, common = {}) => ({ comment: { common: { group_id: VID, status: 1, content: { text }, ...common }, expand: { offset_time: 1500 }, ...extra } });
const payloads = [
  { data: { data_list: [row('第一条'), row('第二条', { expand: { offset_time: '2500' } })], extra: { next_query_danmaku_list_time: '60000' } } },
  { data: { data_list: [row('彩色', {}, { content: { text: '彩色', color: 16711680 } }), row('三位', {}, { content: { text: '三位', color: '#0f8' } })],
    extra: {}, common_list_info: { has_more: true, cursor: '{"end_offset_time": 120000}' } } },
  { data: { data_list: [row('别的视频', {}, { group_id: '1' }), row('待审核', {}, { status: 2 }), row('置顶', { mode: 'top' }), row('底部', { danmaku_type: 3 })],
    common_list_info: { has_more: false, cursor: { end_offset_time: 999999 } } } },
  { data: { data_list: [{ comment: { common: { status: '1', content: { text: '无分组' } }, offset_time: 3000 } }, { nope: 1 }, null],
    extra: { next_query_danmaku_list_time: 5000 }, common_list_info: { has_more: '1', cursor: { next_offset_time: '7000' } } } },
  { data: { data_list: [], extra: { next_query_danmaku_list_time: '0' } } },
  { code: 0 },
];
const parse = payloads.map(payload => ({ payload, expected: danmaku.parsePage(payload, VID) }));
const colors = [16711680, -1, 0, '#abcdef', '#0f8', '0xff00ff', '255', 'red', '', '  #ABC  ', null, 1.5, 0x1ffffff].map(input => ({ input, expected: danmaku.normalizeColor(input) }));
const seconds = [1500, '2500', '12.5', 'abc', -5, 604800001, 604800000, '1e3', null, 0].map(input => ({ input, expected: danmaku.toSeconds(input) }));
const clean = ['  hello  ', 'a\nb\tc', 'x\u2028y', 'ok\u007f'].map(input => ({ input, expected: danmaku.cleanControl(input) }));
const modes = [[{ mode: 'top' }], [{ position: '底部' }], [{ fix_type: 2 }], [{ mode: null }, { danmaku_type: 'fix_bottom' }], [{}]].map(input => ({ input, expected: danmaku.normalizeMode(...input) }));

process.stdout.write(JSON.stringify({ cases, deviceIds, uvarint, vid: VID, parse, colors, seconds, clean, modes }, null, 2) + '\n');

// SPDX-License-Identifier: GPL-3.0-only
// The vector generators replay the upstream Electron reference code, which is no longer kept in
// this repository. Point HONGGUO_UPSTREAM at a checkout of it (the folder that holds src/native).
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const root = process.env.HONGGUO_UPSTREAM;
if (!root) throw new Error('set HONGGUO_UPSTREAM to a checkout of the upstream Electron app');
const native = path.join(path.resolve(root), 'src/native');
if (!fs.existsSync(native)) throw new Error(`no src/native under ${root}`);
module.exports = native;

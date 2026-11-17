// Every place that decides where releases, in-app updates and announcements come from
// must agree with src/native/release-repo.js, so a fork never silently updates from upstream.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const yaml = require('js-yaml');
const repo = require('../src/native/release-repo');

const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');

test('electron-builder publish config matches the release repository', () => {
  const pkg = JSON.parse(read('package.json'));
  assert.deepEqual(pkg.build.publish, { provider: 'github', owner: repo.OWNER, repo: repo.REPO });
});

test('mac directory updater config matches the release repository', () => {
  const config = yaml.load(read('build/app-update.yml'));
  assert.equal(config.provider, 'github');
  assert.equal(config.owner, repo.OWNER);
  assert.equal(config.repo, repo.REPO);
});

test('runtime code takes the repository only from release-repo.js', () => {
  const files = ['main.js', 'src/native/app-update.js', 'src/native/app-update-installer.js', 'src/native/app-announcements.js'];
  for (const file of files) {
    const source = read(file);
    assert.ok(!/github(?:usercontent)?\.com\/(?!\$\{)[\w.-]+\/hongguo-drama/.test(source), `${file} hardcodes a release repository`);
    assert.ok(!/owner:\s*'[\w.-]+'/.test(source), `${file} hardcodes an updater owner`);
  }
  assert.ok(read('src/components/AnnouncementNotice.jsx').includes(repo.ISSUES_URL), 'announcement feedback link must use the release repository');
});

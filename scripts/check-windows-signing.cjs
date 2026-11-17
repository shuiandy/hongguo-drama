const test = require('node:test');
const assert = require('node:assert/strict');
const { signingArgs } = require('./windows-signing-args.cjs');

const full = {
  AZURE_TENANT_ID: 'tenant', AZURE_CLIENT_ID: 'client', AZURE_CLIENT_SECRET: 'secret',
  AZURE_SIGNING_ENDPOINT: 'https://eus.codesigning.azure.net/', AZURE_SIGNING_ACCOUNT: 'acct',
  AZURE_SIGNING_PROFILE: 'profile', WINDOWS_PUBLISHER_NAME: 'Example Publisher',
};

test('no credentials builds unsigned unless signing is required', () => {
  assert.deepEqual(signingArgs({}), { signed: false, args: [] });
  assert.throws(() => signingArgs({ WINDOWS_SIGNING_REQUIRED: 'true' }), /required/);
});

test('complete configuration emits azureSignOptions with publisherName', () => {
  const result = signingArgs(full);
  assert.equal(result.signed, true);
  assert.ok(result.args.includes('--config.win.azureSignOptions.publisherName=Example Publisher'));
  assert.ok(result.args.includes('--config.win.azureSignOptions.endpoint=https://eus.codesigning.azure.net/'));
  assert.ok(!result.args.join(' ').includes('secret'), 'client secret must never reach the command line');
});

test('partial or unsafe configuration fails closed', () => {
  assert.throws(() => signingArgs({ ...full, AZURE_CLIENT_SECRET: '' }), /missing AZURE_CLIENT_SECRET/);
  assert.throws(() => signingArgs({ ...full, AZURE_SIGNING_ENDPOINT: 'http://eus.codesigning.azure.net/' }), /endpoint/);
  assert.throws(() => signingArgs({ ...full, AZURE_SIGNING_ENDPOINT: 'https://evil.example/' }), /endpoint/);
  assert.throws(() => signingArgs({ ...full, WINDOWS_PUBLISHER_NAME: 'a"b' }), /unsupported/);
});

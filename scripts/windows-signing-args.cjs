#!/usr/bin/env node
// Prints electron-builder CLI overrides that enable Windows Authenticode signing via
// Azure Trusted Signing (Artifact Signing). Signing stays out of package.json so that
// local and fork builds without credentials still produce (unsigned) packages.
//
// Required environment when signing:
//   AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET   service principal (read by the TrustedSigning module)
//   AZURE_SIGNING_ENDPOINT          e.g. https://eus.codesigning.azure.net/
//   AZURE_SIGNING_ACCOUNT           Trusted Signing account name
//   AZURE_SIGNING_PROFILE           certificate profile name
//   WINDOWS_PUBLISHER_NAME          certificate subject CN; written to app-update.yml so
//                                   electron-updater verifies every downloaded installer
// Optional:
//   WINDOWS_SIGNING_REQUIRED=true   fail instead of falling back to an unsigned build
//
// Usage: node scripts/windows-signing-args.cjs [--json]
// Output: one argument per line (or a JSON array with --json). Empty when unsigned.
'use strict';

const SIGNING_VARS = ['AZURE_SIGNING_ENDPOINT', 'AZURE_SIGNING_ACCOUNT', 'AZURE_SIGNING_PROFILE', 'WINDOWS_PUBLISHER_NAME'];
const CREDENTIAL_VARS = ['AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET'];

function signingArgs(env = process.env) {
  const all = [...SIGNING_VARS, ...CREDENTIAL_VARS];
  const value = name => String(env[name] || '').trim();
  const present = all.filter(name => value(name));
  const required = /^(1|true|yes)$/i.test(value('WINDOWS_SIGNING_REQUIRED'));
  if (!present.length) {
    if (required) throw new Error(`Windows signing is required but none of ${all.join(', ')} are set`);
    return { signed: false, args: [] };
  }
  const missing = all.filter(name => !value(name));
  if (missing.length) throw new Error(`Windows signing is partially configured; missing ${missing.join(', ')}`);
  const endpoint = new URL(value('AZURE_SIGNING_ENDPOINT'));
  if (endpoint.protocol !== 'https:' || !/\.codesigning\.azure\.net$/i.test(endpoint.hostname)) {
    throw new Error('AZURE_SIGNING_ENDPOINT must be an https://*.codesigning.azure.net/ endpoint');
  }
  for (const name of SIGNING_VARS) {
    if (/[\r\n"]/.test(value(name))) throw new Error(`${name} contains unsupported characters`);
  }
  return {
    signed: true,
    args: [
      `--config.win.azureSignOptions.endpoint=${endpoint.href}`,
      `--config.win.azureSignOptions.codeSigningAccountName=${value('AZURE_SIGNING_ACCOUNT')}`,
      `--config.win.azureSignOptions.certificateProfileName=${value('AZURE_SIGNING_PROFILE')}`,
      `--config.win.azureSignOptions.publisherName=${value('WINDOWS_PUBLISHER_NAME')}`,
    ],
  };
}

if (require.main === module) {
  try {
    const { signed, args } = signingArgs();
    if (!signed) console.error('WARN Windows signing credentials are not configured; building UNSIGNED packages');
    else console.error('INFO Windows packages will be signed with Azure Trusted Signing');
    process.stdout.write(process.argv.includes('--json') ? JSON.stringify(args) : args.join('\n'));
  } catch (error) {
    console.error(`ERROR ${error.message}`);
    process.exit(1);
  }
}

module.exports = { signingArgs, SIGNING_VARS, CREDENTIAL_VARS };

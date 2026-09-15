import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
import { parseDocument } from 'yaml';

export function readConfig(path) {
  const doc = parseDocument(readFileSync(path, 'utf8'), { uniqueKeys: true });
  if (doc.errors.length) throw new Error('Invalid YAML or duplicate keys');
  const config = doc.toJS();
  assert.ok(config && typeof config === 'object' && !Array.isArray(config), 'Expected a YAML mapping');
  return config;
}

export function checkTun(config, stack = 'system') {
  const tun = config.tun;
  assert.ok(tun && typeof tun === 'object' && !Array.isArray(tun), 'Missing tun mapping');
  for (const key of ['enable', 'auto-route', 'auto-detect-interface']) {
    assert.equal(tun[key], true, `tun.${key} must be boolean true`);
  }
  assert.equal(tun.stack, stack, 'Unexpected TUN stack');
  assert.ok(Array.isArray(tun['loopback-address']), 'loopback-address must be a list');
  assert.ok(tun['loopback-address'].includes('10.7.0.1'), 'Missing 10.7.0.1');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.length && (args.length !== 2 || args[0] !== '--effective')) {
      throw new Error('Usage: node check.mjs [--effective /path/to/final-config.yaml]');
    }
    if (args.length) {
      checkTun(readConfig(args[1]));
      console.log('PASS: required fields present; routing and device reachability are NOT tested.');
    } else {
      for (const [name, stack] of [['loopback.patch.yaml', 'system'], ['system.yaml', 'system'], ['gvisor.yaml', 'gvisor'], ['mixed.yaml', 'mixed']]) {
        checkTun(readConfig(new URL(name, import.meta.url)), stack);
      }
      console.log('PASS: packaged YAML fields. Run npm test for script preservation checks.');
    }
  } catch (error) {
    // Do not print a user's full configuration, URLs, or parser excerpts.
    console.error('FAIL:', error.message);
    process.exitCode = 1;
  }
}

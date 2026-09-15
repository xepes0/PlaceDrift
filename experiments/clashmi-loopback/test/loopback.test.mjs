import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';
import { checkTun, readConfig } from '../check.mjs';

const source = readFileSync(new URL('../loopback.js', import.meta.url), 'utf8');
function apply(config) {
  // Same main(object) entry point as Clash Mi; this is not the iOS JS runtime.
  const result = vm.runInNewContext(`${source}\nmain(${JSON.stringify(config)})`, {}, { timeout: 1000 });
  return JSON.parse(JSON.stringify(result));
}

test('minimal YAML and JS agree on required settings', () => {
  const patch = readConfig(new URL('../loopback.patch.yaml', import.meta.url));
  assert.deepEqual(apply({}), patch);
  checkTun(patch);
});

test('preserve subscriptions, rules, DNS, listeners, TUN routes and previous loopbacks', () => {
  const before = {
    proxies: [{ name: '节点', type: 'socks5', server: 'example.invalid', port: 1080 }],
    'proxy-groups': [{ name: '选择', type: 'select', proxies: ['节点'] }],
    'proxy-providers': { sample: { type: 'http', url: 'https://example.invalid/sub' } },
    rules: ['MATCH,选择'], dns: { enable: true, nameserver: ['1.1.1.1'] },
    listeners: [{ name: 'existing', type: 'mixed', port: 7891 }],
    tun: { enable: false, stack: 'gvisor', mtu: 1500, 'dns-hijack': ['any:53'],
      'route-exclude-address': ['192.168.0.0/16'], 'loopback-address': ['10.8.0.1'] }
  };
  const after = apply(before);
  checkTun(after);
  for (const key of Object.keys(before).filter(key => key !== 'tun')) assert.deepEqual(after[key], before[key]);
  for (const key of ['mtu', 'dns-hijack', 'route-exclude-address']) assert.deepEqual(after.tun[key], before.tun[key]);
  assert.deepEqual(after.tun['loopback-address'], ['10.8.0.1', '10.7.0.1']);
  assert.deepEqual(apply(after), after, 'repeated application must be idempotent');
});

test('malformed input fails explicitly instead of silently deleting data', () => {
  for (const input of [null, [], 'text', { tun: true }, { tun: [] }, { tun: { 'loopback-address': '10.8.0.1' } }, { tun: { 'loopback-address': [42] } }]) {
    assert.throws(() => apply(input));
  }
});

test('detect fields overwritten after applying the script', () => {
  for (const change of [{ enable: false }, { stack: 'gvisor' }, { 'loopback-address': [] }, { 'auto-route': 'true' }]) {
    const config = apply({});
    Object.assign(config.tun, change);
    assert.throws(() => checkTun(config));
  }
});

test('standalone profiles are direct-only and do not require subscriptions', () => {
  for (const stack of ['system', 'gvisor', 'mixed']) {
    const config = readConfig(new URL(`../${stack}.yaml`, import.meta.url));
    checkTun(config, stack);
    assert.deepEqual(config.rules, ['MATCH,DIRECT']);
    assert.deepEqual(config.proxies, []);
    assert.deepEqual(config['proxy-groups'], []);
    assert.equal(config['allow-lan'], false);
  }
});

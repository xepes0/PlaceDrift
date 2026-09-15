import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const overridePath = 'experiments/browser-wasm/clashmi-wloc-bridge.js';
const htmlPath = 'experiments/browser-wasm/transport-test.html';

const source = fs.readFileSync(overridePath, 'utf8');
const context = {};
vm.createContext(context);
vm.runInContext(source, context, { filename: overridePath });
assert.equal(typeof context.main, 'function');

const input = {
  tun: {
    enable: true,
    stack: 'system',
    'loopback-address': ['192.0.2.1'],
  },
  listeners: [
    { name: 'keep-me', type: 'socks', port: 1080 },
    { name: 'wloc-browser-bridge', type: 'vless', port: 1 },
  ],
};

const output = context.main(input);
assert.equal(output.tun.enable, true);
assert.equal(output.tun.stack, 'mixed');
assert.ok(output.tun['loopback-address'].includes('10.7.0.1'));
assert.ok(output.tun['loopback-address'].includes('192.0.2.1'));

const bridge = output.listeners.filter((x) => x?.name === 'wloc-browser-bridge');
assert.equal(bridge.length, 1);
assert.equal(bridge[0].type, 'vless');
assert.equal(bridge[0].listen, '127.0.0.1');
assert.equal(bridge[0].port, 17890);
assert.equal(bridge[0]['ws-path'], '/wloc');
assert.equal(bridge[0]['allow-insecure'], true);
assert.equal(bridge[0].users[0].uuid, 'b8842e9c-72fd-4a59-9f8d-5f3b9e9b5d2a');
assert.equal(output.listeners.some((x) => x?.name === 'keep-me'), true);

const html = fs.readFileSync(htmlPath, 'utf8');
assert.match(html, /ws:\/\/127\.0\.0\.1:17890\/wloc/);
assert.match(html, /b8842e9c-72fd-4a59-9f8d-5f3b9e9b5d2a/);
assert.match(html, /example\.com/);

console.log('browser-wasm override and transport smoke-test assets validated');

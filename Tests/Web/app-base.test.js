'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');
const WEB = path.join(__dirname, '../../Sources/Baguette/Resources/Web');

function loadTarget(pathname) {
  const location = new URL(pathname, 'https://example.test');
  const window = { location };
  vm.runInNewContext(fs.readFileSync(path.join(WEB, 'target.js'), 'utf8'), { window, location, URL });
  return window.BaguetteTarget;
}

for (const route of ['/simulators', '/devices/ID', '/farm', '/farm/farm.html', '/baguette-demo.html']) {
  for (const prefix of ['', '/subpath', '/nested/proxy', '/simulators', '/devices']) {
    test(`should keep requests beneath the app mount when opening ${prefix}${route}`, () => {
      const target = loadTarget(prefix + route);
      assert.equal(target.url('/devices.json'), prefix + '/devices.json');
      assert.equal(target.url('simulators.json'), prefix + '/simulators.json');
      assert.equal(target.pathname, route);
      assert.equal(target.base, route.startsWith('/devices/') ? 'devices' : 'simulators');
      assert.equal(target.path('a/b', '/input'), `${prefix}/${target.base}/a%2Fb/input`);
      assert.equal(target.wsURL(target.path('ID', '/stream?format=avcc')),
        `wss://example.test${prefix}/${target.base}/ID/stream?format=avcc`);
    });
  }
}

test('should preserve resolved and external URLs without adding the mount twice', () => {
  const target = loadTarget('/subpath/simulators/ID/');
  for (const url of ['/subpath/devices.json', 'https://cdn.test/a.png',
    '//cdn.test/a.png', 'data:image/png;base64,abc', 'blob:https://example.test/abc']) {
    assert.equal(target.url(url), url);
  }
  assert.equal(target.pathname, '/simulators/ID/');
  assert.equal(target.url('/simulators/ID/bezel.png?panel=cover'),
    '/subpath/simulators/ID/bezel.png?panel=cover');
  assert.equal(target.wsURL('wss://remote.test/custom/stream'), 'wss://remote.test/custom/stream');
});

for (const page of ['sim.html', 'farm/farm.html', 'baguette-demo.html']) {
  test(`should load ${page} assets beneath the mount before opening a device`, () => {
    const html = fs.readFileSync(path.join(WEB, page), 'utf8');
    const location = new URL('https://example.test/nested/proxy/' +
      (page === 'sim.html' ? 'devices/ID' : page));
    const bases = [];
    const document = {
      createElement: () => ({}),
      head: { appendChild: (base) => bases.push(base) },
    };
    const bootstrap = html.slice(0, html.indexOf('</head>')).match(/<script>([\s\S]*?)<\/script>/);
    assert.ok(bootstrap, 'inline base bootstrap');
    vm.runInNewContext(bootstrap[1], { location, document, URL });
    assert.equal(bases[0].href, 'https://example.test/nested/proxy/');
    assert.ok(bootstrap.index < html.search(/<(?:script[^>]+src|link[^>]+href)=/));
    for (const [, asset] of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
      if (/^(?:https?:)?\/\//.test(asset) || asset.startsWith('#')) continue;
      assert.ok(new URL(asset, bases[0].href).pathname.startsWith('/nested/proxy/'), asset);
    }
    assert.match(html, /src="target\.js"/);
  });
}

test('should resolve definition artwork beneath the app mount and an explicit server base', () => {
  const location = new URL('https://example.test/subpath/simulators/ID');
  const window = loadBrowserModules([path.join(WEB, 'baguette/baguette.js')], {
    location, BaguetteTarget: loadTarget(location.pathname),
  });
  const make = () => ({
    screen: { bezelImage: { rest: '/simulators/ID/bezel.png', bare: '/simulators/ID/bezel.png?buttons=false' },
      maskImage: '/simulators/ID/screen-mask.png' },
    buttons: [{ images: { rest: '/simulators/ID/button.png', pressed: 'data:image/png;base64,abc' } }],
  });
  const def = window.Baguette.normalizeDefinition(make());
  assert.equal(def.screen.bezelImage.rest, 'https://example.test/subpath/simulators/ID/bezel.png');
  assert.equal(def.screen.maskImage, 'https://example.test/subpath/simulators/ID/screen-mask.png');
  assert.equal(def.buttons[0].images.rest, 'https://example.test/subpath/simulators/ID/button.png');
  assert.equal(def.buttons[0].images.pressed, 'data:image/png;base64,abc');
  window.Baguette.normalizeDefinition(def);
  assert.equal(def.screen.maskImage, 'https://example.test/subpath/simulators/ID/screen-mask.png');
  const remote = window.Baguette.normalizeDefinition(make(), 'https://remote.test/custom');
  assert.equal(remote.screen.bezelImage.bare,
    'https://remote.test/custom/simulators/ID/bezel.png?buttons=false');
});

test('should fetch CarPlay definitions and artwork beneath the app mount', async (t) => {
  const target = loadTarget('/subpath/simulators/ID');
  const window = loadBrowserModules([
    path.join(WEB, 'baguette/carplay/frame-definition.js'),
    path.join(WEB, 'baguette/carplay/frame-registry.js'),
  ], { BaguetteTarget: target });
  const requests = [];
  t.mock.method(globalThis, 'fetch', async (url) => {
    requests.push(url);
    return { ok: true, json: async () => requests.length === 1
      ? [{ id: 'plain', definition: 'plain/definition.json' }]
      : { schemaVersion: 1, id: 'plain', viewport: { width: 100, height: 100 },
        screen: { x: 0, y: 0, width: 100, height: 80 }, layers: [],
        stream: { defaultSize: { width: 100, height: 80 }, fit: 'contain' } } };
  });
  const packed = await window.Baguette._CarPlayFrameRegistry.load('plain');
  assert.deepEqual(requests, ['/subpath/carplay-frames/registry.json',
    '/subpath/carplay-frames/plain/definition.json']);
  assert.equal(packed.assetBaseUrl, '/subpath/carplay-frames/plain/');
  assert.equal(packed.definition.layerImageUrl({ image: '/carplay-frames/plain/a.png' }, packed.assetBaseUrl),
    '/subpath/carplay-frames/plain/a.png');
  assert.equal(packed.definition.layerImageUrl({ image: 'a.png' }, packed.assetBaseUrl),
    '/subpath/carplay-frames/plain/a.png');
  assert.equal(packed.definition.layerImageUrl({ image: 'data:image/png;base64,abc' }, packed.assetBaseUrl),
    'data:image/png;base64,abc');
});

test('should bootstrap a device through the mount and honor an explicit remote server', async (t) => {
  const requests = [];
  t.mock.method(globalThis, 'fetch', async (url) => {
    requests.push(url);
    return { ok: true, json: async () => ({ screen: { maskImage: '/devices/ID/mask.png' }, buttons: [] }) };
  });
  const window = loadBrowserModules([path.join(WEB, 'baguette/baguette.js')], {
    location: new URL('https://example.test/subpath/devices/ID'),
    BaguetteTarget: loadTarget('/subpath/devices/ID'),
    Baguette: { _Transport: class {}, _Simulator: class { constructor(def) { this.def = def; } } },
  });
  const local = await window.Baguette.use({ udid: 'ID', send() {}, definitionURL: '/subpath/devices/ID/definition.json' });
  assert.equal(requests[0], '/subpath/devices/ID/definition.json');
  assert.equal(local.def.screen.maskImage, 'https://example.test/subpath/devices/ID/mask.png');
  const remote = await window.Baguette.use({ udid: 'ID', send() {}, host: 'https://remote.test/custom/' });
  assert.equal(requests[1], 'https://remote.test/custom/simulators/ID/definition.json');
  assert.equal(remote.def.screen.maskImage, 'https://remote.test/custom/devices/ID/mask.png');
  for (const base of ['devices', 'simulators']) {
    await window.Baguette.use({ udid: 'ID', send() {}, host: `https://remote.test/${base}/`,
      definitionURL: `/${base}/ID/definition.json` });
    assert.equal(requests.at(-1), `https://remote.test/${base}/${base}/ID/definition.json`);
  }
});

test('should keep external CarPlay artwork on its explicit asset host', () => {
  const window = loadBrowserModules([path.join(WEB, 'baguette/carplay/frame-definition.js')], {
    BaguetteTarget: loadTarget('/subpath/simulators/ID'),
  });
  const def = window.Baguette._CarPlayFrameDefinition.parse({
    schemaVersion: 1, id: 'plain', viewport: { width: 100, height: 100 },
    screen: { x: 0, y: 0, width: 100, height: 80 }, layers: [],
    stream: { defaultSize: { width: 100, height: 80 }, fit: 'contain' },
  });
  assert.equal(def.layerImageUrl({ image: '/carplay-frames/plain/a.png' }, 'https://cdn.test/carplay-frames/plain/'),
    'https://cdn.test/carplay-frames/plain/a.png');
});

test('should recognize a device page when the route has extra trailing slashes', () => {
  const target = loadTarget('/subpath/simulators/ID//');
  assert.equal(target.url('target.js'), '/subpath/target.js');
});

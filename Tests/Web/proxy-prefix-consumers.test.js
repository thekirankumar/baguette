'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const vm = require('node:vm');
const fs = require('node:fs');

const WEB = path.join(__dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web');
const appURL = pathname => pathname.startsWith('/proxy/team/')
  ? pathname : '/proxy/team/' + pathname.replace(/^\/+/, '');

function load(file, seed = {}) {
  const context = {
    location: { pathname: '/proxy/team/simulators/a%2Fb', protocol: 'https:', host: 'example.com' },
    document: { addEventListener() {} },
    console,
    URLSearchParams,
    BaguetteTarget: {
      pathname: '/simulators/a%2Fb',
      url: appURL,
      path: (udid, rest) => appURL('/simulators/' + encodeURIComponent(udid) + rest),
      wsURL: pathname => 'wss://example.com' + appURL(pathname),
    },
    ...seed,
  };
  context.window = context;
  vm.runInNewContext(fs.readFileSync(path.join(WEB, file), 'utf8'), context);
  return context;
}

for (const file of ['sim-list.js', 'sim-native.js', 'sim-stream.js', 'sim-camera.js',
  'sim-location.js', 'sim-screens.js', 'sim-status-bar.js', 'sim-network.js',
  'sim-file-drop.js', 'sim-plugins.js', 'farm/farm-app.js']) {
  for (const mount of ['/simulators', '/devices']) {
    test(`should keep raw app routes beneath an overlapping ${mount} mount in ${file}`, () => {
      const location = new URL(`https://example.com${mount}/simulators/ID`);
      const window = { location };
      const context = { window, URL };
      vm.runInNewContext(fs.readFileSync(path.join(WEB, 'target.js'), 'utf8'), context);
      const wrapper = fs.readFileSync(path.join(WEB, file), 'utf8')
        .match(/const appURL =[^\n]+;/);
      assert.ok(wrapper, 'raw app route wrapper');
      vm.runInNewContext(wrapper[0] + '\nwindow.appURL = appURL;', context);
      for (const route of ['/simulators/ID/network', '/devices/ID', '/simulators', '/devices']) {
        assert.equal(window.appURL(route), mount + route);
      }
      const resolved = window.BaguetteTarget.path('ID', '/stream');
      assert.equal(window.BaguetteTarget.url(resolved), resolved);
      window.BaguetteTarget = undefined;
      assert.equal(window.appURL('/simulators/ID/network'), '/simulators/ID/network');
    });
  }
}

test('should activate the native page using its app-relative pathname', () => {
  // Stop after activation, before mounting the rest of the page.
  const sentinel = new Error('activated');
  const context = {
    location: { pathname: '/proxy/team/simulators/a%2Fb' },
    BaguetteTarget: { pathname: '/simulators/a%2Fb' },
  };
  Object.defineProperty(context, '__baguetteNativeMode', {
    set(value) { assert.equal(value, true); throw sentinel; },
  });
  context.window = context;
  assert.throws(() => vm.runInNewContext(
    fs.readFileSync(path.join(WEB, 'sim-native.js'), 'utf8'), context
  ), error => error === sentinel);
});

test('should ingest farm definitions with prefix-aware artwork', async () => {
  const urls = [];
  const def = { frame: { image: '/frames/phone.png' } };
  const context = load('farm/farm-app.js', {
    FarmFilter: class {},
    Baguette: { normalizeDefinition(value) { value.frame.image = appURL(value.frame.image); return value; } },
    fetch: async url => { urls.push(url); return { ok: true, json: async () => def }; },
  });
  const app = new context.FarmApp();
  app.devices = [{ udid: 'a/b', uiState: 'live' }];
  await app.loadDefinitions();
  assert.deepEqual(urls, ['/proxy/team/simulators/a%2Fb/definition.json']);
  assert.equal(app.definitions.get('a/b'), def);
  assert.equal(def.frame.image, '/proxy/team/frames/phone.png');
});

test('should preserve standalone farm definition ingestion', async () => {
  const urls = [];
  const def = { frame: { image: '/frames/phone.png' } };
  const context = load('farm/farm-app.js', {
    BaguetteTarget: undefined,
    FarmFilter: class {},
    fetch: async url => { urls.push(url); return { ok: true, json: async () => def }; },
  });
  const app = new context.FarmApp();
  app.devices = [{ udid: 'a/b', uiState: 'live' }];
  await app.loadDefinitions();
  assert.deepEqual(urls, ['/simulators/a%2Fb/definition.json']);
  assert.equal(app.definitions.get('a/b'), def);
});

test('should preserve the proxy prefix for camera and log sockets', () => {
  for (const prefixed of [false, true]) {
    const urls = [];
    const context = load('sim-camera.js', {
      ...(prefixed ? {} : { BaguetteTarget: undefined }),
      WebSocket: class {
        constructor(url) { urls.push(url); }
        addEventListener() {}
      },
    });
    const camera = new context.CameraPanel();
    camera.udid = 'a/b';
    camera._openSocket();
    vm.runInNewContext(fs.readFileSync(path.join(WEB, 'sim-logs.js'), 'utf8'), context);
    const logs = Object.create(context.LogPanel.prototype);
    Object.assign(logs, { udid: 'a/b', level: 'info', style: 'compact', bundleId: 'my app' });
    logs._connect();
    const base = 'wss://example.com' + (prefixed ? '/proxy/team' : '');
    assert.deepEqual(urls, [
      base + '/simulators/a%2Fb/camera',
      base + '/simulators/a%2Fb/logs?level=info&style=compact&bundleId=my+app',
    ]);
  }
});

test('should preserve the proxy prefix once for a 3D stream path', () => {
  const urls = [];
  const context = load('sim-3d.js', {
    StreamSession: class {
      constructor(opts) { urls.push(opts.url); }
      start() {}
    },
  });
  const panel = new context.Sim3DPanel();
  Object.assign(panel, {
    udid: 'a/b', model: {}, canvas: {}, format: 'mjpeg',
    stop() {}, setState() {}, outputSize: () => ({ width: 100, height: 200 }),
  });
  panel.start();
  const url = new URL(urls[0]);
  assert.equal(url.origin, 'wss://example.com');
  assert.equal(url.pathname, '/proxy/team/simulators/a%2Fb/stream.3d.mjpeg');
  assert.equal(url.searchParams.get('width'), '100');
});

test('should preserve the proxy prefix for network and plugin HTTP requests', async () => {
  const urls = [];
  const context = load('sim-network.js', {
    fetch: async url => { urls.push(url); return { ok: false, json: async () => ({ ok: true }) }; },
  });
  const network = new context.NetworkPanel();
  network.udid = 'a/b';
  await network._hydrate();
  vm.runInNewContext(fs.readFileSync(path.join(WEB, 'sim-plugins.js'), 'utf8'), context);
  const plugins = Object.create(context.PluginPanels.prototype);
  plugins.udid = 'a/b';
  await plugins.invoke('plugin', { id: 'panel', body: {} }, 'plugin/id', 'command name');
  assert.deepEqual(urls, [
    '/proxy/team/simulators/a%2Fb/network',
    '/proxy/team/plugins/plugin%2Fid/commands/command%20name?udid=a%2Fb',
  ]);
});

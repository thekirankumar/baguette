'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');
const { FakeElement } = require('./helpers/fake-dom.js');

const WEB = path.join(__dirname, '../../Sources/Baguette/Resources/Web');
const panel = { id: 'build:install', title: 'Install build', body: {
  kind: 'list', source: 'build:install', prompt: { arg: 'url', submit: 'Install' },
} };
const queued = { id: 'run-1', command: 'build:install', udid: 'sim-1', state: 'queued' };

for (const name of ['gitlab-artifacts', 'url-download']) {
  test(`should offer a URL install panel without saving sensitive URLs for ${name}`, () => {
    const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '../../plugins', name, 'baguette-plugin.json')));
    const install = manifest.contributes.panels?.find(p => p.body.source === 'install');
    assert.ok(install);
    assert.equal(install.when, 'simulator.booted');
    assert.equal(install.body.prompt.arg, 'url');
    assert.equal(install.body.prompt.submit, 'Install');
    assert.ok(!install.body.prompt.history);
  });
}

function fixture(t) {
  const timers = new Map();
  let nextTimer = 0;
  const window = loadBrowserModules(['plugin-prompt.js', 'sim-plugins.js'].map(f => path.join(WEB, f)), {
    BaguetteTarget: { url: p => '/team/' + p },
    setTimeout(fn) { const id = ++nextTimer; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); },
  });
  const ui = new window.PluginPanels({ udid: 'sim-1', mount: {}, modalMount: {} });
  ui.plugins = [{ name: 'build', commands: [{ id: 'build:install', background: true }] }];
  ui.host = { innerHTML: '', hidden: false };
  ui.rail = { querySelectorAll: () => [] };
  ui.renderShell = (_name, _panel, html) => { ui.host.innerHTML = html; };
  const requests = [];
  let reply = { status: 202, body: queued };
  t.mock.method(global, 'fetch', async (url, init) => {
    requests.push({ url, init });
    if (reply instanceof Error) throw reply;
    return { ok: reply.status >= 200 && reply.status < 300, status: reply.status,
      json: async () => reply.body };
  });
  return { ui, requests, timers, reply(value) { reply = value; }, async tick() {
    const [id, fn] = timers.entries().next().value;
    timers.delete(id);
    await fn();
  } };
}

test('should offer an install prompt without starting a background run when its panel opens', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  assert.equal(f.requests.length, 0);
  assert.match(f.ui.host.innerHTML, /Ready/);
});

test('should leave input syntax and action labels to the plugin when background work is ready', async t => {
  const f = fixture(t);
  const generic = { ...panel, body: { ...panel.body, prompt: { arg: 'ref', submit: 'Build' } } };
  await f.ui.open('build', generic);
  assert.doesNotMatch(f.ui.host.innerHTML, /URL|Install/);
});

test('should target the focused simulator and preserve the mount prefix when starting an install', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  f.ui.promptValue = 'https://builds.example.com/app.zip';
  await f.ui.submitPrompt('build', panel);
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].url, '/team/plugins/build/commands/install/runs?udid=sim-1');
  assert.deepEqual(JSON.parse(f.requests[0].init.body), { args: { url: f.ui.promptValue } });
  assert.match(f.ui.host.innerHTML, /Queued/);
  assert.match(f.ui.host.innerHTML, /<progress/);
  assert.equal(f.timers.size, 1);
});

test('should ignore duplicate submissions while an install is starting or running', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  f.ui.promptValue = 'https://builds.example.com/app.zip';
  await Promise.all([f.ui.submitPrompt('build', panel), f.ui.submitPrompt('build', panel)]);
  await f.ui.submitPrompt('build', panel);
  assert.equal(f.requests.length, 1);
});

test('should show downloaded bytes without inventing a percentage and stop polling after success', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  await f.ui.startBackground('build', panel, { url: 'https://builds.example.com/app.zip' });
  f.reply({ status: 200, body: { ...queued, state: 'running', phase: 'downloading', downloadedBytes: 1048576 } });
  await f.tick();
  assert.equal(f.requests[1].url, '/team/runs/run-1.json');
  assert.match(f.ui.host.innerHTML, /downloading/i);
  assert.match(f.ui.host.innerHTML, /1(?:\.0)? MiB/);
  assert.doesNotMatch(f.ui.host.innerHTML, /value="/);
  f.reply({ status: 200, body: { ...queued, state: 'succeeded', phase: 'installing' } });
  await f.tick();
  assert.match(f.ui.host.innerHTML, /Succeeded/);
  assert.equal(f.timers.size, 0);
});

test('should display an escaped failure even when the status request succeeds', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  await f.ui.startBackground('build', panel, { url: 'x' });
  f.reply({ status: 200, body: { ...queued, state: 'failed', message: '<img src=x onerror=alert(1)>' } });
  await f.tick();
  assert.match(f.ui.host.innerHTML, /Failed/);
  assert.match(f.ui.host.innerHTML, /&lt;img/);
  assert.doesNotMatch(f.ui.host.innerHTML, /<img/);
  assert.equal(f.timers.size, 0);
});

test('should stop browser polling without cancelling the install when its panel closes and resume on reopen', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  await f.ui.startBackground('build', panel, { url: 'x' });
  f.ui.close();
  assert.equal(f.timers.size, 0);
  assert.equal(f.requests.length, 1);
  f.reply({ status: 200, body: { ...queued, state: 'succeeded' } });
  await f.ui.open('build', panel);
  assert.equal(f.requests.length, 2);
  assert.equal(f.requests[1].init.method, 'GET');
  assert.match(f.ui.host.innerHTML, /Succeeded/);
});

test('should preserve the run and retry status rather than restart the install after a polling error', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  await f.ui.startBackground('build', panel, { url: 'x' });
  f.reply(new Error('offline'));
  await f.tick();
  assert.match(f.ui.host.innerHTML, /status.*unavailable/i);
  assert.equal(f.timers.size, 1);
  f.reply({ status: 200, body: { ...queued, state: 'cancelled' } });
  await f.tick();
  assert.match(f.ui.host.innerHTML, /Cancelled/);
  assert.equal(f.requests.filter(r => r.init.method === 'POST').length, 1);
});

test('should allow another attempt when the server explicitly rejects a start', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  f.reply({ status: 409, body: { error: 'simulator busy' } });
  await f.ui.startBackground('build', panel, { url: 'x' });
  assert.match(f.ui.host.innerHTML, /simulator busy/);
  f.reply({ status: 202, body: queued });
  await f.ui.startBackground('build', panel, { url: 'x' });
  assert.equal(f.requests.length, 2);
});

test('should describe an HTML proxy refusal by HTTP status instead of an unconfirmed start', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  t.mock.method(global, 'fetch', async () => ({ status: 400,
    json: async () => { throw new SyntaxError('Unexpected token <'); },
  }));
  await f.ui.startBackground('build', panel, { url: 'https://builds.example.com/app.zip' });
  assert.match(f.ui.host.innerHTML, /HTTP 400/);
  assert.doesNotMatch(f.ui.host.innerHTML, /not confirmed/i);
  assert.equal(f.ui.backgroundBusy(panel), false);
  assert.equal(f.timers.size, 0);
});

test('should retain uncertainty and describe the HTTP status when the proxy fails with HTML', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  t.mock.method(global, 'fetch', async () => ({ status: 502,
    json: async () => { throw new SyntaxError('Unexpected token <'); },
  }));
  await f.ui.startBackground('build', panel, { url: 'https://builds.example.com/app.zip' });
  assert.match(f.ui.host.innerHTML, /not confirmed/i);
  assert.match(f.ui.host.innerHTML, /HTTP 502/);
  assert.equal(f.ui.backgroundBusy(panel), true);
});

test('should block automatic resubmission when a start response is lost', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  f.reply(new Error('offline'));
  await f.ui.startBackground('build', panel, { url: 'x' });
  assert.match(f.ui.host.innerHTML, /not confirmed/i);
  await f.ui.startBackground('build', panel, { url: 'x' });
  assert.equal(f.requests.length, 1);
});

test('should resume progress when its panel is reopened before the start response arrives', async t => {
  const f = fixture(t);
  let accept;
  t.mock.method(global, 'fetch', () => new Promise(resolve => { accept = resolve; }));
  await f.ui.open('build', panel);
  const pending = f.ui.startBackground('build', panel, { url: 'x' });
  f.ui.close();
  await f.ui.open('build', panel);
  accept({ status: 202, json: async () => queued });
  await pending;
  assert.match(f.ui.host.innerHTML, /Queued/);
  assert.equal(f.timers.size, 1);
});

test('should ignore a stale running response after a reopened panel has observed success', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  await f.ui.startBackground('build', panel, { url: 'x' });
  let respond;
  const fetchMock = t.mock.method(global, 'fetch', () => new Promise(resolve => { respond = resolve; }));
  const oldPoll = f.tick();
  f.ui.close();
  fetchMock.mock.restore();
  f.reply({ status: 200, body: { ...queued, state: 'succeeded' } });
  await f.ui.open('build', panel);
  respond({ ok: true, json: async () => ({ ...queued, state: 'running' }) });
  await oldPoll;
  assert.equal(f.ui.backgroundRuns.get(panel.body.source).state, 'succeeded');
});

test('should keep synchronous panels on their existing command endpoint', async t => {
  const f = fixture(t);
  f.ui.plugins[0].commands[0].background = false;
  f.reply({ status: 200, body: { ok: true, rows: [] } });
  f.ui.renderRows = (_name, _panel, rows) => { f.ui.rows = rows; };
  await f.ui.open('build', panel);
  assert.equal(f.requests[0].url, '/team/plugins/build/commands/install?udid=sim-1');
  assert.deepEqual(f.ui.rows, []);
});

test('should lock the prompt while active and unlock it after a terminal outcome', async t => {
  const f = fixture(t);
  class Element extends FakeElement {
    constructor() { super(); this.children = []; this.attributes = {}; }
    appendChild(child) { this.children.push(child); }
    setAttribute(key, value) { this.attributes[key] = value; }
  }
  const original = global.document;
  global.document = { createElement: () => new Element() };
  t.after(() => { global.document = original; });
  f.ui.paintGhost = () => {};
  const mount = () => {
    const slot = new Element();
    f.ui.host = { querySelector: () => slot };
    f.ui.mountPrompt('build', panel, f.ui.promptFor(panel));
    return { input: slot.children[0].children[1], button: slot.children[1] };
  };
  f.ui.backgroundRuns.set(panel.body.source, queued);
  const active = mount();
  assert.equal(active.input.readOnly, true);
  assert.equal(active.button.disabled, true);
  assert.equal(active.input.attributes.autocomplete, 'off');
  f.ui.backgroundRuns.set(panel.body.source, { ...queued, state: 'succeeded' });
  const finished = mount();
  assert.equal(finished.input.readOnly, false);
  assert.equal(finished.button.disabled, false);
});

test('should not accept another simulator or an arbitrary status URL as the started run', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  f.reply({ status: 202, body: { ...queued, id: 'https://attacker.test/run', udid: 'sim-2' } });
  await f.ui.startBackground('build', panel, { url: 'x' });
  assert.match(f.ui.host.innerHTML, /not confirmed/i);
  assert.equal(f.timers.size, 0);
});

test('should leave a newly opened panel untouched when the old start completes', async t => {
  const f = fixture(t);
  await f.ui.open('build', panel);
  let accept;
  t.mock.method(global, 'fetch', () => new Promise(resolve => { accept = resolve; }));
  const pending = f.ui.startBackground('build', panel, { url: 'x' });
  const other = { ...panel, id: 'build:other', body: { ...panel.body, source: 'build:other' } };
  f.ui.plugins[0].commands.push({ id: 'build:other', background: true });
  await f.ui.open('build', other);
  accept({ status: 202, json: async () => queued });
  await pending;
  assert.match(f.ui.host.innerHTML, /Ready/);
  assert.equal(f.timers.size, 0);
  assert.equal(f.ui.backgroundRuns.get(panel.body.source).id, 'run-1');
});

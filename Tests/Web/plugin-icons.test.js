'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

test('should show the locally bundled GitLab fox with its official colours in the plugin rail', t => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '../../plugins/gitlab-artifacts/baguette-plugin.json')));
  assert.equal(manifest.icon, 'gitlab');
  assert.equal(manifest.contributes.panels[0].icon, 'gitlab');
  const button = { setAttribute() {}, addEventListener() {} };
  const previous = global.document;
  global.document = { createElement: () => button };
  t.after(() => { global.document = previous; });
  const window = loadBrowserModule(path.join(__dirname, '../../Sources/Baguette/Resources/Web/sim-plugins.js'));
  const ui = new window.PluginPanels({ udid: 'sim', mount: {}, modalMount: {} });
  ui.rail = { appendChild() {} };
  ui.addGroup({ name: manifest.name, icon: manifest.icon, panels: manifest.contributes.panels });
  for (const colour of ['#e24329', '#fc6d26', '#fca326']) assert.ok(button.innerHTML.includes(colour));
  assert.match(button.innerHTML, /stroke="none"/);
  assert.doesNotMatch(button.innerHTML, /href=|<script|<style/);
});

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'stream-session.js'
);

function loadStreamSession(seed) {
  const window = Object.assign({
    location: { protocol: 'http:', host: 'localhost:8421' },
  }, seed || {});
  return loadBrowserModules([MODULE_PATH], window);
}

test('should stream the default display when no display is requested', () => {
  const { StreamSession } = loadStreamSession();
  const url = StreamSession.buildWSUrl('UDID-1', 'mjpeg', 'v2');
  assert.equal(
    url,
    'ws://localhost:8421/simulators/UDID-1/stream?format=mjpeg&version=v2'
  );
});

test('should stream CarPlay when its display is requested', () => {
  const { StreamSession } = loadStreamSession();
  const url = StreamSession.buildWSUrl('UDID-1', 'mjpeg', 'v2', 'carplay');
  assert.equal(
    url,
    'ws://localhost:8421/simulators/UDID-1/stream?format=mjpeg&version=v2&display=carplay'
  );
});

test('should stream the phone when its display is requested', () => {
  const { StreamSession } = loadStreamSession();
  const url = StreamSession.buildWSUrl('UDID-1', 'avcc', 'v2', 'phone');
  assert.equal(
    url,
    'ws://localhost:8421/simulators/UDID-1/stream?format=avcc&version=v2&display=phone'
  );
});

test('should preserve the device identity when it contains URL separators', () => {
  const { StreamSession } = loadStreamSession();
  const url = StreamSession.buildWSUrl('a/b', 'mjpeg', 'v2', 'external');
  assert.equal(
    url,
    'ws://localhost:8421/simulators/a%2Fb/stream?format=mjpeg&version=v2'
  );
});

test('should preserve the proxy prefix for simulator and device streams', () => {
  for (const base of ['simulators', 'devices']) {
    const { StreamSession } = loadStreamSession({
      BaguetteTarget: {
        base,
        path: (udid, rest) => `/proxy/team/${base}/${encodeURIComponent(udid)}${rest}`,
        wsURL: pathname => `wss://example.com${pathname}`,
      },
    });
    assert.equal(
      StreamSession.buildWSUrl('a/b', 'mjpeg', 'v2', 'phone'),
      `wss://example.com/proxy/team/${base}/a%2Fb/stream?format=mjpeg&version=v2&display=phone`
    );
  }
});

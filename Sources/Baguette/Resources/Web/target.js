// The one place the page knows WHAT it is driving. `/simulators/:udid`
// and `/devices/:udid` serve the same sim.html; every module builds
// its resource URLs through this seam so a physical device reuses the
// whole page with the base path switched. Loaded before every other
// script.
(function () {
  'use strict';

  const loc = window.location;
  // Match the rightmost page route so even a /simulators proxy prefix survives.
  const route = loc.pathname.match(/^(.*)(\/(?:simulators|devices)(?:\/[^/]+)?\/*|\/farm(?:\/farm\.html)?\/*|\/(?:baguette-demo|sim)\.html)$/);
  const mount = route ? route[1] + '/' : new URL('./', loc.href).pathname;
  const pathname = loc.pathname.slice(mount.length - 1);
  const parts = pathname.split('/').filter(Boolean);
  const base = parts[0] === 'devices' ? 'devices' : 'simulators';

  function url(path) {
    if (/^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(path)) return path;
    // Raw app routes should be relative; absolute mounted paths are already resolved.
    if (mount !== '/' && path.startsWith(mount)) return path;
    return mount + path.replace(/^\/+/, '');
  }

  window.BaguetteTarget = {
    /** App-relative route and proxy-aware HTTP/navigation URLs. */
    pathname,
    url,
    wsURL(path) {
      const resolved = new URL(url(path), loc.href);
      if (resolved.protocol === 'https:') resolved.protocol = 'wss:';
      else if (resolved.protocol === 'http:') resolved.protocol = 'ws:';
      return resolved.href;
    },
    /** 'simulators' | 'devices' — the resource root this page drives. */
    base,
    /** True on /devices/:udid — a physical phone behind the mirror. */
    isDevice: base === 'devices',
    /** '/devices/<udid><rest>' or '/simulators/<udid><rest>'. */
    path(udid, rest) {
      return url(base + '/' + encodeURIComponent(udid) + (rest || ''));
    },
  };
})();

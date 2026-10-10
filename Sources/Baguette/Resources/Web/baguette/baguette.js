// Baguette SDK — the entry point.
//
//   const sim = await Baguette.use({ host, udid, send });
//   sim.mount(container);
//
// Public surface (everything else under `Baguette._*` is internal):
//   Baguette.version  — semver string
//   Baguette.use      — bootstrap a Simulator
//
// `host` is an optional server base URL, including its proxy mount.
// `udid` is the simulator's UDID. `send` is the upstream sink — a
// `(payload)=>void` function the page wires to its WebSocket. The
// SDK never opens its own socket; the consumer owns transport
// lifecycle so it can multiplex frames + control on one WS.
//
// SDK design rules (enforced by code review, not the compiler):
//   • Only `transport.js` knows the wire format.
//   • Each part is its own class in `parts/<name>.js`.
//   • Gesture interpreters live in `gestures/<name>.js` and call
//     domain methods on parts — never wire envelopes.
//   • Adding a new part doesn't change the public API.
(function (root) {
  'use strict';

  root.Baguette = root.Baguette || {};
  root.Baguette.version = '0.1.0';

  function serverURL(path, host) {
    if (/^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(path)) return path;
    if (!host && root.BaguetteTarget) return root.BaguetteTarget.url(path);
    const base = new URL((host || root.location.origin).replace(/\/+$/, '') + '/');
    return new URL(path.replace(/^\/+/, ''), base).href;
  }

  // Definitions use server-root paths; resolve them once before DOM parts mount.
  root.Baguette.normalizeDefinition = function (def, host) {
    const imageBase = host || (root.BaguetteTarget
      ? new URL(root.BaguetteTarget.url(''), root.location.href).href : root.location.origin);
    const imageURL = path => serverURL(path, imageBase);
    const images = [def.screen && def.screen.bezelImage,
      ...(def.buttons || []).map((button) => button.images)];
    for (const image of images) {
      if (!image) continue;
      for (const state of ['rest', 'bare', 'pressed']) {
        if (image[state]) image[state] = imageURL(image[state]);
      }
    }
    if (def.screen && def.screen.maskImage) {
      def.screen.maskImage = imageURL(def.screen.maskImage);
    }
    return def;
  };

  /**
   * Fetch the simulator's definition and return a ready Simulator.
   * @param {object} opts
   * @param {string} [opts.host] baguette server base URL (including proxy mount)
   * @param {string} opts.udid
   * @param {(payload:object)=>void} opts.send  wire sink
   * @param {(msg:string, isErr?:boolean)=>void} [opts.log]
   * @returns {Promise<Simulator>}
   */
  root.Baguette.use = async function use({ host, udid, send, log, getOrientation, definitionURL }) {
    if (!udid) throw new Error('Baguette.use: udid is required');
    if (typeof send !== 'function') throw new Error('Baguette.use: send must be a function');

    // `definitionURL` lets a non-simulator surface (a physical device
    // borrowing a chrome) point the bootstrap somewhere else.
    const url = serverURL(definitionURL || `simulators/${encodeURIComponent(udid)}/definition.json`, host);
    const res  = await fetch(url, { cache: 'no-cache' });
    if (!res.ok) {
      throw new Error(`Baguette.use: definition fetch failed (${res.status})`);
    }
    const def = root.Baguette.normalizeDefinition(await res.json(), host);

    const T = root.Baguette._Transport;
    const transport = new T({ send, log });
    return new root.Baguette._Simulator(def, transport, { getOrientation, log });
  };
})(window);

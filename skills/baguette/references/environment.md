# Environment — the conditions the app runs under

Read when: testing how an app behaves somewhere else, moving, on a bad
network, in dark mode or large text, with a camera feed, a push
notification, a shake, or a staged status bar. None of these are touches;
most shell out to `simctl` or inject a dylib. Flags: that command's `## baguette <cmd>` section of `commands.md`.

**The relaunch rule.** `motion`, `network` and `camera` work by injecting a
dylib, so only apps launched *after* arming see them. Relaunch with
`xcrun simctl launch --terminate-running-process <X> <bundle-id>`.

## Location

```bash
baguette location set   --udid <X> 37.3318,-122.0312
baguette location start --udid <X> --speed 5 37.33,-122.03 37.34,-122.02   # route
baguette location walk  --udid <X> --bearing 90 --speed 1.4 37.33,-122.03
baguette location clear --udid <X>
```

Points are `lat,lon` tokens; one whose latitude starts with `-` must follow
`--`. `CLHeading` (compass) is unavailable in the simulator; `walk` drives
`CLLocation.course`, which skews on diagonal bearings by `1/cos(latitude)`.
HTTP: `POST|DELETE /simulators/<X>/location`. See
[location](https://github.com/tddworks/baguette/blob/main/docs/features/location/README.md).

## Motion (CoreMotion)

```bash
baguette motion start --udid <X> --activity running   # plain start = walking
baguette motion set   --udid <X> --activity cycling
baguette motion stop  --udid <X>
```

Feeds `CMMotionActivity`, `CMPedometer` and `CMMotionManager`, none of which
a stock simulator has. Relaunch rule applies. Floors and the magnetometer
stay unavailable. HTTP: `POST|GET|DELETE /simulators/<X>/motion`. See
[motion](https://github.com/tddworks/baguette/blob/main/docs/features/motion/README.md).

## Network

```bash
baguette network set   --udid <X> --profile 3g    # wifi | dsl | lte | 3g | edge | very-bad-network | 100-loss
baguette network set   --udid <X> --latency 300 --bandwidth 400 --loss 5
baguette network set   --udid <X> --offline
baguette network       --udid <X>                 # what's applied
baguette network clear --udid <X>
```

Exactly one of profile / custom / offline per call. Relaunch rule applies to
starting; a later `set` or `clear` takes effect at once, no relaunch. Only URLSession traffic is
conditioned (WebSocket tasks too, except bandwidth): SDKs with their own
sockets (ably-cocoa, Starscream) and `WKWebView` / Safari page loads are not,
and loss is per request. HTTP: `POST|GET|DELETE /simulators/<X>/network`. See
[network](https://github.com/tddworks/baguette/blob/main/docs/features/network/README.md).

## Appearance, contrast, text size

```bash
baguette interface appearance --udid <X> dark     # no value reads
baguette interface contrast   --udid <X> enabled
baguette interface text-size  --udid <X> accessibility-extra-large
```

A read on a device that isn't booted answers `unknown` (exit 0);
`unsupported` means the runtime lacks it. Change the setting, re-run
`describe-ui`, compare. HTTP: `GET /simulators/<X>/interface.json`,
`POST /simulators/<X>/interface`. See
[interface](https://github.com/tddworks/baguette/blob/main/docs/features/interface/README.md).

## Status bar

```bash
baguette status-bar override --udid <X> --time 9:41 --battery-level 100 --wifi-bars 3
baguette status-bar clear    --udid <X>
```

For clean screenshots. See
[status bar](https://github.com/tddworks/baguette/blob/main/docs/features/status-bar/README.md).

## Push notifications

```bash
baguette press  --udid <X> --button home           # banners need a backgrounded app
baguette notify --udid <X> --bundle-id com.example.app --file push.json
```

Success means the simulator accepted the payload, not that a banner showed;
the reply's `expectation` says what to look for (the app also needs
notification permission). Find the banner with `describe-ui`, then tap it.
HTTP: `POST /simulators/<X>/notify?bundleId=`. See
[notifications](https://github.com/tddworks/baguette/blob/main/docs/features/notifications/README.md).

## Shake

`baguette shake --udid <X>` fires UIKit's `motionShake` (undo, debug menus).

## Camera

No CLI. Over `WS /simulators/<X>/camera`: `camera_list`, `camera_start`
(`source: webcam | image | video`), `camera_stop`, `camera_set_flags`; the
server answers `camera_devices` / `camera_state`. Upload an image or video
first with `POST /simulators/<X>/camera-source?name=<file>`. Relaunch rule
applies. A failed stop answers `cleanupRequired: true`; reconnect and stop
again before another source. See
[camera](https://github.com/tddworks/baguette/blob/main/docs/features/camera/README.md).

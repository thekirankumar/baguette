---
description: Press and hold a simulated device's hardware buttons — home, lock, power, volume, action — or open the app switcher. Use when a flow needs a side-button tap or a timed long-press.
---

# Hardware buttons

Press-and-release of the physical side buttons on a simulated device: home,
lock, power, volume up / down, and the iPhone 15 Pro's action button.
Every flag: [commands.md#baguette-press](../../commands.md#baguette-press).

## Quick start

```bash
baguette press --udid <UDID> --button home
baguette press --udid <UDID> --button action --duration 1.2   # long-press
baguette press --udid <UDID> --button app-switcher
```

In `baguette serve`, turn on `actionable` mode and each chrome button in the
rendered bezel becomes a real button: click → tap; click and hold → a real
long-press (the page forwards the `mousedown` → `mouseup` time as `duration`).

## Buttons

| Name           | iOS effect                              |
|----------------|-----------------------------------------|
| `home`         | Home / app switcher                     |
| `lock`         | Sleep / wake                            |
| `power`        | Sleep / wake (modern devices)           |
| `volume-up`    | Volume up                               |
| `volume-down`  | Volume down                             |
| `action`       | iPhone 15 Pro action button             |
| `software-keyboard` | Toggle the on-screen keyboard; see [Keyboard](../keyboard/README.md#software-keyboard) |
| `app-switcher` | Multitasking carousel (cards)           |

`app-switcher` is a *virtual* button — there's no physical equivalent on Face
ID iPhones. It's sent as a double home press ~150 ms apart, which works across
the iPhone X+ family regardless of rotation. The slow swipe-and-hold variant,
and the other gesture-backed names (`swipe-to-home`, `pull-down-to-…`), are
[touches](../touches/README.md). The watch's `digital-crown` / `side-button` /
`left-side-button` are covered in [companion-screens](../companion-screens/README.md).

## Hold duration

`duration` is seconds. `0` (or absent) → a ~100 ms tap; non-zero is the
down→up hold time, clamped to a 20 ms floor so a bogus `0.001` doesn't
underrun the simulator's HID dispatch. iOS distinguishes tap vs long-press for
almost every side button:

| Button         | Short tap                | Long hold (≥ ~0.8 s)        |
|----------------|--------------------------|------------------------------|
| `action`       | Fires the assigned shortcut | "Hold for Ring" / silent flip |
| `power`        | Sleep / wake             | Siri (≥ ~1.5 s) / Emergency SOS slider (≥ ~5 s) |
| `volume-up`    | Volume up                | Accessibility shortcut       |
| `volume-down`  | Volume down              | Accessibility shortcut       |
| `home`/`lock`  | n/a (already long-press unsafe at the legacy path) | n/a |

The page measures the hold for you; programmatic clients have to pass
`duration` themselves — there's no implicit hold.

## Wire

The same press goes over `baguette serve`'s WebSocket and `baguette input`'s
stdin; the envelope is in [wire.md](../../wire.md):

```json
{ "type": "button", "button": "action", "duration": 1.2 }
```

HID codes are never on the wire — the button name is enough.

## Gotchas

- **`siri` is explicitly rejected.** Every known Indigo path crashes
  `backboardd`. Don't expect it to come back without a working recipe.
- **Long holds block.** The dispatch sleeps for the hold, so holds beyond
  ~5 s block the calling thread. Streaming clients that need concurrent input
  during a hold should split it into separate `down` / `up` events through
  `touch1`.
- **iPhone Duo's keys** ignore the legacy press; baguette routes a foldable's
  buttons another way for you — see [iphone-duo](../iphone-duo/README.md).
- **Xcode 27:** once Device Hub attaches, presses report ok and do nothing
  until healed — see [device-hub](../device-hub/README.md).

## See also

- [design.md](design.md) — the two SimulatorKit paths, the magic numbers and where they come from
- [touches](../touches/README.md) · [shake](../shake/README.md)

# TrackSteer

Two-finger drag becomes a held middle mouse button — in one app only.

## Why

In World of Warcraft, a mouse-turner holds a button and moves the mouse to run
and steer, which frees the whole left hand for abilities. A Mac trackpad has no
middle button and can't hold right-click while dragging, so that entire style of
play is unavailable on a laptop. TrackSteer supplies the missing button.

Rest two fingers and move: your character runs and steers. Nothing is held down,
which turns out to be more comfortable than the mouse it imitates.

## How it works

macOS already reports two-finger movement as a scroll event carrying
pixel-precise deltas — that *is* the gesture, already smoothed and accelerated
by the system. So TrackSteer intercepts the scroll and re-emits it as
middle-button drag. Apple's private multitouch API is used only to count
fingers, which sidesteps the version-fragile touch struct entirely.

That's why this is ~300 lines and one file with no dependencies.

Everything is scoped to a single application. Two-finger scrolling is far too
important to break system-wide, so outside the target app every event passes
through untouched.

## Build

Needs Xcode command line tools. No project file, no packages.

```bash
./build.sh
```

Builds `TrackSteer.app`, ad-hoc signs it, and installs to `~/Applications`.

## Setup

1. Launch it, then grant **Accessibility** in System Settings → Privacy &
   Security. Intercepting and posting input events is exactly what that
   permission governs, so it cannot work without it.
2. Bind `MOVEANDSTEER` to the middle mouse button in WoW. The
   [BindSwap](../bindswap-addon) addon does this in one click via its
   **Trackpad 2-finger** preset.

## Configuration

At the top of `Sources/main.swift`:

- `targetBundleIDs` — which apps it applies to
- `fingerCount` — fingers required (2)
- `sensitivity` — scales trackpad movement into mouse movement

Run with `TRACKSTEER_DEBUG=1` to log finger counts and tap activity to stderr.

## Notes

- Two-finger scroll is consumed inside the target app, so camera zoom needs
  keys. BindSwap's preset binds `=` and `-`.
- Three fingers is left alone — macOS uses it for Spaces.
- Ad-hoc signed, so distributing it means users see a Gatekeeper warning unless
  it's notarized, which requires a paid Apple Developer account.

## Licence

MIT.

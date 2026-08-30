# TrackSteer

Two fingers turn your character. Press down and they move it. In one app only.

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

## Install

**[Download the latest release](https://github.com/purexmalice/TrackSteer/releases/latest)**
— no Xcode, no Terminal, no building anything.

1. Unzip and drag `TrackSteer.app` into your Applications folder.
2. **Right-click it and choose Open** — not a double-click. macOS will say the
   developer cannot be verified, because the app is signed by me rather than
   paid-for-and-notarised through Apple. Right-click → Open gives you a button
   to open it anyway. You only do this once.
3. It appears in the menu bar as **TS**. Click it and choose *Open Accessibility
   settings…*, then tick TrackSteer in the list. It cannot read the trackpad
   without that, and it will tell you so until you do.

Then bind **Move and Steer** to the middle mouse button in World of Warcraft.
The [BindSwap](https://github.com/purexmalice/BindSwap) addon does it in one
click with its Trackpad setup button.

### Updating

macOS ties Accessibility permission to the app's exact signature, and that
changes with every build — so after updating, **remove the old TrackSteer entry
in Accessibility with the `−` button and add it back**. Toggling it off and on
is not enough. [NOTARIZING.md](NOTARIZING.md) explains how to end that
permanently.

## Building it yourself

Only needed if you want to change something. Requires Xcode command line tools;
there is no project file and no dependencies.

```bash
./build.sh
```

Builds `TrackSteer.app`, ad-hoc signs it, and installs to `~/Applications`.

## Settings

Changed with `defaults`, and picked up within a couple of seconds — no restart:

```bash
# Turn speed. 1.0 tracks the system's own trackpad acceleration.
defaults write com.jthorney.tracksteer sensitivity -float 1.5

# Fingers required for the drag (2-4).
defaults write com.jthorney.tracksteer fingerCount -int 2

# Which apps it applies to. Everywhere else is left completely alone.
defaults write com.jthorney.tracksteer targetBundleIDs -array com.blizzard.worldofwarcraft
```

Back to defaults:

```bash
defaults delete com.jthorney.tracksteer
```

Run with `TRACKSTEER_DEBUG=1` to log finger counts and tap activity to stderr.

## Notes

- Two-finger scroll is consumed inside the target app, so camera zoom needs
  keys. BindSwap's preset binds `=` and `-`.
- Three fingers is left alone — macOS uses it for Spaces.
- Ad-hoc signed by default, so users see a Gatekeeper warning and macOS revokes
  Accessibility on every update. See [NOTARIZING.md](NOTARIZING.md) to sign it
  properly with a Developer ID, which fixes both.

## Licence

MIT.

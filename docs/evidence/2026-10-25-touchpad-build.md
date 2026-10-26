# 2026-10-25: a personal build with the on-screen controller

**Fork:** Pustoy-inside/playport, branch `main`. **Status:** built on GitHub's
hosted runners, not yet tested on a phone.

## What it carries on top of playportdev/playport `main` (412de5f8)

- **nVoxel/playport's personal unsigned build** (`.github/workflows/personal-ipa.yml`,
  `ci/`): the Apple SDK made on a `macos-26` runner from its Xcode 26.6, handed to
  the Linux runner encrypted, `./pp build --variant release --unsigned` there, the
  IPA in an owner-only draft release. Its three Swift fixes for the newer compiler
  (`GalaxyListener.swift`, `Catalog.swift`, `PadTheme.swift`) and its recorded
  manifests come with it. Changed here: the repository name, a `precheck` job that
  compiles the touch pad for iOS first, iloader in the install note.
- **PR #59** (Unreal games: start the shipping executable when Steam names the
  bootstrap) and **PR #53** (host pads in the raw input list, as HID devices and as
  Windows.Gaming.Input gamepads).
- **Pavel Demyanov's on-screen controller** (PavelDemyanov/playport,
  `touchpad-prototype`, tag `v0.4.0-touchpad.3`): `contrib/touchpad/PlayportTouchPad.m`,
  there a library injected into the released 0.4.0 IPA, here
  `app/Sources/TouchPad/touchpad.m`, a target of the app:
  - Playport's entry points are called, not found with `dlsym`: `host_pad_set`,
    `wine_host_set_log_limit`, `host_log_set_limit`, and the in-game menu through
    two `@_cdecl` functions (`UI/TouchPadBridge.swift`) instead of Swift symbols
    called with `swiftcall`.
  - `PlayportApp.init` calls `playport_touchpad_linked()` so the linker keeps the
    object, and with it the constructor.
  - Its environment no longer sets `MADEIRA_KEEP_SMC=1` (FEX 0.4.0's Mono fault;
    `main` has fex 0033/0038/0040 and per-title defaults) nor a
    `WINEDLLOVERRIDES` (it existed to stop HostIO disabling windows.gaming.input;
    PR #53 leaves it enabled). `SDL_JOYSTICK_RAWINPUT=0`, the Baldur's Gate 3
    settings and `Documents/playport-diag.env` are unchanged.
- **Pavel Demyanov's Wine patches** (`contrib/wine`), as `patches/wine-pe` 0048–0052:
  - 0048, the `__C_specific_handler` target unwind (issue #58), and 0049, host pad
    hot-plug (`WM_DEVICECHANGE`, the Windows.Gaming.Input provider), as he built
    them for arm64ec; they apply to every architecture.
  - 0050 (a new thread is returned once it has started) and 0052 (dsound keeps six
    periods queued) rebased onto `main`'s series and built for i386 only, the
    scope he tested (Half-Life 2).
  - 0051 (`SDL_JOYSTICK_RAWINPUT=0` at kernelbase attach) as he wrote it.
  - His i386 `MEM_DECOMMIT` patch is left out: `main` fixes the same in
    madeira-unix 0107.

The series applies with `git am -3` onto the wine pin plus wine-port, wine-valve
and wine-pe (checked on a wine-mirror checkout of 455e3509).

## Not known yet

Whether the app builds with the touch pad target, whether the touch pad, Home and
the menu work on `main`'s UI, and whether any game behaves differently. Each of
those needs the phone.

## 2026-10-26: first install on the phone (run 40240512146)

The IPA (`Playport-26.5-release-unsigned-428b0c51.ipa`, sha256 `428b0c51…ef15`)
installed over 0.4.0 with iloader; Increased Memory Limit on. The on-screen
controller connects (`hostio: controller connected "Apple Touch Controller"`,
XInput slot 0).

The Witcher 3 (292030) no longer starts: Steam names `REDprelauncher.exe`, which
adoption skips, and its fallback took the first executable at the folder's top,
`setup_redlauncher.exe`, which quits with exit code 1 after about 0.5 s (six tries,
Vulkan and DXMT, with and without `-dx11`). 0.4.0 started `bin\x64\witcher3.exe`.
Fix: `Adoption.pick` passes over an installer, redistributable or tool at the top
when the game is below it, and the game page's Executable picker now also shows
for Steam games (a chosen executable other than Steam's launch one drops the
launch entry's arguments).

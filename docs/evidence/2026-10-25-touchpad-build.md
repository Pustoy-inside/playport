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

Deep Rock Galactic (548430) now starts and plays (two sessions, 121 s and 397 s,
exit 0; DXMT), where 0.4.0 showed a black screen. Its Steam Cloud saves did not
come down: 0.4.0 had synced them (22 down, 2026-10-24), the phone then held none
of them, and the sync took that for deletions, which are not carried (44 on
Steam, 0 on the phone, 0 down). The game started without saves, and the next
sync sent its fresh `76561199019898212_Player.sav` up over Steam's copy, since
Steam's had not changed since the last sync; nothing kept Steam's copy. Fix:
when the phone holds none of the files the last sync left, Steam's copies come
down as on a first sync; and every upload that replaces a Steam file backs that
file up first (`backups/<appid>/<time>/`), not only a conflict the player settles.

## 2026-10-26: The Witcher 3's expansions, and what an update deletes

Build 8 starts The Witcher 3 (`bin\x64\witcher3.exe`), and Deep Rock Galactic
plays with its saves. The Witcher 3's saves from the expansions do not load:
the app's installs pass `DepotSelection` no `ownedDLC`, so every DLC depot was
left out ("DLC app … not owned"; Hearts of Stone and Blood and Wine are depots
378648 and 378649), while the emulator's profile tells the game the account
owns 19 DLC. Fix: a DLC depot an owned package lists (`ownedDepots`) is owned;
the game page offers **Download DLC** when the emulator's owned DLC have depots
the install lacks.

Adding them was a whole reinstall: an update stages the full plan in a new
tree and swaps it in, so a 60 GB title downloaded 60 GB again, and the swap
deleted every file the game had written in its folder. Deep Rock Galactic keeps
its saves in `FSD/Saved/SaveGames`, inside its install, and was updated on
2026-10-26 09:42 UTC: that is how the phone came to hold none of its synced
saves. Fix: an update in place keeps each file whose path, size and SHA-1 the
installed build's retained manifests already have (hard links into the stage),
downloads only the rest, and hard-links every file in neither build's manifests
(saves, settings) into the new tree before the swap.

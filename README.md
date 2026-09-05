# ClipSync

Wireless clipboard sync (text + images) between macOS and Windows machines on
the same Wi‑Fi network. No server, no internet, and clipboard content is never
written to disk — it is transferred over an encrypted LAN socket and lives only
in memory and in the system clipboard.

## How it works

| Concern | Implementation |
| --- | --- |
| Discovery | Bonjour/mDNS service `_clipsync._tcp` via `bonsoir`. TXT record carries the device id and name. |
| Transport | Direct TCP between peers, 4‑byte length‑prefixed frames (`lib/net/frame_codec.dart`). |
| Encryption | X25519 (ephemeral + static) → HKDF‑SHA256 → ChaCha20‑Poly1305 per frame (`lib/net/crypto.dart`). |
| Pairing | First contact shows a 6‑digit PIN (and QR) on the accepting device; the PIN is the HKDF salt, so a wrong PIN fails authentication and the link is dropped. Paired static keys are remembered so later connections are automatic. |
| Clipboard | Native channels: `NSPasteboard` (Swift) and Win32 clipboard API (C++). PNG is the wire format for images. |
| Change detection | Windows: `AddClipboardFormatListener` / `WM_CLIPBOARDUPDATE`. macOS has no notification API, so the native layer compares `NSPasteboard.changeCount` every 150 ms (an integer read, no content access). |
| Loop prevention | SHA‑256 of the last item written from a peer plus a small LRU of recently broadcast hashes (`lib/sync/sync_engine.dart`). |
| Tray | `tray_manager` + `window_manager`; closing the window hides it (Dock icon hidden on macOS). |
| Overlay | Second Flutter engine (`overlayMain`) in a native borderless, non‑activating, always‑on‑top panel (`OverlayPanel.swift`, `overlay_window.cpp`). |

Only settings, the device identity key and the list of trusted peers are
persisted (via `shared_preferences`). There is no clipboard history.

## Layout

```
lib/
  app/app_state.dart        composition root, tray + window lifecycle, pairing dialogs
  core/                     models, settings store, identity / trusted peers
  net/                      discovery, frame codec, crypto, peer connection, peer manager
  platform/                 Dart side of the clipboard / overlay / system channels
  sync/sync_engine.dart     clipboard <-> peers glue, loop prevention
  ui/                       main window, settings, pairing dialogs, overlay card
macos/Runner/               ClipboardPlugin.swift, OverlayPanel.swift, SystemPlugin.swift
windows/runner/             clipboard_plugin.cpp, overlay_window.cpp, system_plugin.cpp
```

## Build & run

```sh
flutter pub get
flutter run -d macos      # on a Mac
flutter run -d windows    # on a PC
```

### Testing with two instances on one Mac

One build can be launched twice with separate identities/settings:

```sh
flutter build macos --debug
BIN=build/macos/Build/Products/Debug/clipsync.app/Contents/MacOS/clipsync
CLIPSYNC_INSTANCE=a $BIN &
CLIPSYNC_INSTANCE=b $BIN &
```

Both instances share the Mac's single clipboard, so a "sync" simply re‑sets the
same content; the hash guard prevents any loop. Use a second machine for a real
end‑to‑end check.

### Tests

```sh
flutter test
```

Covers frame codec, the crypto handshake (matching/wrong PIN, tampering),
models, and a loopback pairing + text/image exchange between two `PeerManager`s.

## First run

1. Open ClipSync on both machines. They appear in each other's device list.
2. Click **Pair** on one. The other shows a PIN; type it into the first.
3. Copy anything. The other machine's clipboard updates and a popup slides in.

Settings (gear icon or tray menu): popup corner, fade vs. edge‑slide,
auto‑dismiss 3 s / 5 s / 8 s / never, sound, image sync, launch at login, and
the click action:

* **Dismiss only** (default) — content is already on the clipboard; paste manually.
* **Paste into the active app** — clicking the popup sends ⌘V / Ctrl+V to the
  frontmost window. On macOS this needs Accessibility permission; the settings
  screen offers a button to request it and the option stays disabled until granted.

## Notes

* macOS sandbox is disabled in the entitlements: posting keyboard events and
  unrestricted LAN sockets are not available to sandboxed apps.
* `NSBonjourServices` and `NSLocalNetworkUsageDescription` are set in
  `Info.plist` (required by macOS 14+ for Bonjour).
* If mDNS is blocked on your network, expand **Connect manually** in the main
  window and enter the other device's IP and the port shown in its status bar.
* The Windows runner code was written on a Mac and has not been compiled here.
  Build with `flutter build windows` on a PC and report any compiler errors.

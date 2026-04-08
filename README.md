# simvault_interceptor

A Flutter package that automatically intercepts network traffic for
**SimVault** — a macOS tool for saving, restoring, and replaying iOS Simulator
app state and network sessions.

The interceptor supports three modes: **record** (capture traffic to tape files),
**replay** (return recorded responses offline), and **intercept** (tamper with
live requests/responses). It also handles **secure storage persistence** —
dumping and restoring `flutter_secure_storage` Keychain entries so login state
survives snapshot restores.

Activation is controlled by a `simvault_session.json` file that SimVault writes
to the app's Documents directory before launching. When this file is absent
(normal dev runs, CI, etc.) every method is a **complete no-op**, so it is safe
to leave the interceptor in your codebase.

---

## Important: init ordering

`SimVaultInterceptor.init()` must be called **right after
`WidgetsFlutterBinding.ensureInitialized()`** and **before** any auth/state
initialisation or `runApp()`.

The binding must be initialized first because `path_provider` (used internally
to locate `Documents/simvault_session.json`) requires it. After that, `init()`
must run before auth logic so that keystore restore completes before the app
reads Keychain entries.

```dart
import 'package:simvault_interceptor/simvault_interceptor.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Right after binding init — before any auth/state setup
  await SimVaultInterceptor.init();

  // ... other setup (auth, providers, etc.) ...
  runApp(const MyApp());
}
```

---

## Release builds

**Never include `simvault_interceptor` in release builds.** Use a dev-only
dependency or conditional import:

```yaml
# pubspec.yaml
dev_dependencies:
  simvault_interceptor: ^0.1.0
```

Or use a conditional import so the interceptor code is tree-shaken in release:

```dart
import 'package:flutter/foundation.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    await SimVaultInterceptor.init();
  }
  // ... other setup ...
  runApp(const MyApp());
}
```

The `KeystoreManager` has belt-and-suspenders guards: `assert(!kReleaseMode)`
plus a runtime `kReleaseMode` check that makes every method a no-op. But
the safest approach is to not ship the package at all.

---

## Supported HTTP clients

| Client | How it's intercepted |
|--------|----------------------|
| `package:http` | `SimVaultInterceptor.wrapHttpClient(client)` |
| `Dio` | `SimVaultInterceptor.addDioInterceptor(dio)` |
| `dart:io HttpClient` | Automatic via `HttpOverrides.global` |

---

## Usage

### 1. Initialise in `main()`

```dart
import 'package:simvault_interceptor/simvault_interceptor.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SimVaultInterceptor.init();  // right after binding init
  runApp(const MyApp());
}
```

### 2. Wrap your HTTP clients

#### `package:http`

```dart
final client = SimVaultInterceptor.wrapHttpClient(http.Client());
final response = await client.get(Uri.parse('https://api.example.com/data'));
```

#### Dio

```dart
final dio = Dio();
SimVaultInterceptor.addDioInterceptor(dio); // no-op when inactive
```

#### `dart:io HttpClient`

No additional setup needed. `SimVaultInterceptor.init()` installs a global
`HttpOverrides` that wraps every `HttpClient` instance automatically.

---

## Modes

| Mode | Network | What happens |
|------|---------|--------------|
| `record` | Real | Every request/response saved to tape. Keystore dumped automatically. |
| `replay` | None | Recorded responses returned (FIFO per endpoint). Cache miss falls through to real network. |
| `intercept` | Real | Outgoing request body can be modified; response status/body can be overridden. |
| `dump_keystore` | None | Dumps keystore to file and returns. Used by Quick Save. |
| `restore_only` | None | Restores keystore then stays inactive. Used by Quick Save restore. |

The mode is set by SimVault via `Documents/simvault_session.json`:

```json
{"sessionId": "93c8dc3f-...", "mode": "replay", "restoreKeystore": true}
```

The `restoreKeystore` field is only present when SimVault has injected a
keystore file that needs to be restored to the Keychain before the app runs.

---

## Secure storage persistence (keystore)

### Problem

`flutter_secure_storage` stores auth tokens in the iOS Keychain, which lives
outside the app's data container. SimVault's container snapshots don't capture
Keychain items, so login state is lost on restore.

### Solution

The interceptor can dump all `flutter_secure_storage` entries to a JSON file
and restore them on the next launch — before auth logic runs.

**On save (Record Session):** The interceptor automatically dumps the keystore
on `init()` when in record mode. The file (`Documents/simvault_keystore.json`)
sits alongside the tape files. When SimVault calls `stopRecording()`, it copies
the keystore file into the snapshot directory. No separate app launch needed.

**On save (Quick Save):** After saving the container, SimVault briefly launches
the app with `mode: "dump_keystore"`. The interceptor dumps the keystore and
SimVault copies the file into the snapshot directory. This adds ~2-3 seconds.

**On restore (Session Record):** SimVault writes the keystore file back into
`Documents/` and sets `restoreKeystore: true` in the session config (replay or
intercept mode). On `init()`, the interceptor restores Keychain entries, deletes
the plaintext file, then activates the requested mode.

**On restore (Quick Save):** Same keystore injection, but with
`mode: "restore_only"`. The interceptor restores Keychain entries then stays
completely inactive — the app runs normally with no interception.

**If the keystore file is missing or malformed** when `restoreKeystore: true`
is set, `init()` logs a warning and continues normally — it does not throw or
block the app from launching. The app will simply start without the restored
Keychain entries (i.e. logged out).

### Security considerations

- The keystore file contains **plaintext Keychain contents**. This is a
  dev-only trade-off.
- All `KeystoreManager` methods are guarded by `assert(!kReleaseMode)` and a
  runtime `kReleaseMode` check — they are complete no-ops in release builds.
- The plaintext file is deleted immediately after restore.
- **Never ship this package in a release build.**

### What gets captured

`flutter_secure_storage` is a flat key-value store shared across the entire
app. Dumping captures *all* keys, including entries from third-party SDKs
(analytics, crash reporting, payment SDKs). Restoring stale third-party keys
may cause unexpected behaviour.

- **v1:** All keys are captured. This is a known limitation.
- **Future:** Optional key prefix filter via
  `SimVaultInterceptor.init(keystoreKeys: ['auth_token', 'refresh_token'])`.

### Simulator-only

This file-based approach requires writing to `Documents/` before app launch,
which is only possible on the iOS Simulator. Real device support would require
a different transport mechanism.

---

## API reference

```dart
// Activate the interceptor (call once, first line of main()).
await SimVaultInterceptor.init();

// Wrap a package:http client.
http.Client SimVaultInterceptor.wrapHttpClient(http.Client client);

// Attach a Dio interceptor.
void SimVaultInterceptor.addDioInterceptor(Dio dio);

// Check status.
bool SimVaultInterceptor.isActive;
```

---

## Known limitations

- **Binary bodies:** Binary response bodies (images, protobuf, etc.) are
  stored as `<binary N bytes>` in tape files rather than base64-encoded.
  These entries replay as that placeholder string, not the original bytes.
- **Replay cache miss:** If the app makes a request that wasn't recorded in
  the tape, the interceptor falls through to the real network.
- **Web platform:** `dart:io` is not available on the web; this package
  targets iOS / Android / macOS / Linux / Windows Flutter targets only.

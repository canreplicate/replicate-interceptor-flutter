# replicate_interceptor

This package is a companion for the [Replicate App](https://canreplicate.app) — install Replicate on your Mac, add this package to your Flutter app, and you're ready to record, restore, and tamper with your iOS Simulator sessions.

[![Replicate](https://canreplicate.app/og-image.png)](https://canreplicate.app)

---

Flutter package that gives Replicate visibility into your app's network traffic. Add it to your Flutter app once; Replicate activates it on demand before each session.

It supports two active modes: **record** (capture all traffic to tape files) and **intercept** (tamper with live requests/responses, serve manual endpoints without hitting the network). It also handles **secure storage persistence** — dumping and restoring `flutter_secure_storage` Keychain entries so login state survives snapshot restores.

Activation is controlled by a `replicate_session.json` file that Replicate writes to the app's Documents directory before launching. When that file is absent — normal dev runs, CI, production — every method is a **complete no-op**. It is safe to leave this package in your codebase indefinitely.

---

## Install

```yaml
# pubspec.yaml — add as a dev dependency so it's excluded from release builds
dev_dependencies:
  replicate_interceptor: ^0.1.0
```

Or guard it at runtime (belt-and-suspenders):

```dart
import 'package:flutter/foundation.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    await ReplicateInterceptor.init();
  }
  runApp(const MyApp());
}
```

The `KeystoreManager` also has internal `assert(!kReleaseMode)` + runtime `kReleaseMode` guards, but the safest approach is to not ship the package at all.

---

## Setup

### 1. Initialise in `main()` — before anything else

```dart
import 'package:replicate_interceptor/replicate_interceptor.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Must be first — before auth, providers, runApp
  await ReplicateInterceptor.init();

  // ... other setup ...
  runApp(const MyApp());
}
```

`init()` must run right after `WidgetsFlutterBinding.ensureInitialized()` because `path_provider` (used to locate `Documents/replicate_session.json`) requires the binding, and it must complete before auth logic so keystore restore finishes before the app reads Keychain entries.

### 2. Wrap your HTTP clients

#### `package:http`

```dart
final client = ReplicateInterceptor.wrapHttpClient(http.Client());
final response = await client.get(Uri.parse('https://api.example.com/data'));
```

#### Dio

```dart
final dio = Dio();
ReplicateInterceptor.addDioInterceptor(dio); // no-op when inactive
```

#### `dart:io HttpClient`

No extra setup. `init()` installs a global `HttpOverrides` that wraps every `HttpClient` instance automatically.

---

## Supported HTTP clients

| Client | How it's intercepted |
|--------|----------------------|
| `package:http` | `ReplicateInterceptor.wrapHttpClient(client)` |
| `Dio` | `ReplicateInterceptor.addDioInterceptor(dio)` |
| `dart:io HttpClient` | Automatic via `HttpOverrides.global` |

---

## Modes

Replicate sets the mode by writing `Documents/replicate_session.json` before launching your app:

```json
{"sessionId": "93c8dc3f-...", "mode": "intercept", "restoreKeystore": true}
```

| Mode | Network | What happens |
|------|---------|--------------|
| `record` | Real | Every request/response saved to tape. Keystore dumped automatically. |
| `intercept` | Real (except manual entries) | Manual tape entries served locally without network. Outgoing request body can be modified; response status/body can be overridden. |
| `dump_keystore` | None | Dumps keystore to file and returns. Used by Quick Save. |
| `restore_only` | None | Restores keystore then stays inactive. Used by Quick Save restore. |

> `replay` mode still exists in the package code for backwards compatibility but is no longer triggered by Replicate. Session Records use `intercept` mode exclusively.

---

## What you can test with intercept mode

Intercept mode runs against the **real network** for all normal requests — but lets you manipulate specific calls. Here's how to choose the right approach:

| What you want to test | How |
|---|---|
| How does the **real API** behave when I send a wrong/modified request? | Use **intercept** with a `requestBodyOverride` — Replicate sends your overridden request to the real server and you get the real response |
| How does the **app UI** behave when it receives a specific error response? | Create a **manual tape entry** in Replicate with the desired error response — interceptor returns it without any network call |
| Mock an endpoint that doesn't exist yet or can't be called safely | Add a **manual tape entry** — the app gets your fake response; everything else hits the real network |

**Example — testing OTP validation:**
- You have a recording where a correct OTP was submitted.
- To test the *app's UI* for an OTP error: create a manual tape entry for the OTP endpoint with an error response → run Intercept → the app receives the fake error with zero network calls.
- To test the *real API's* behaviour: use an override with a wrong OTP in `requestBodyOverride` → the real API receives the wrong OTP and returns a real error.

---

## Secure storage persistence (keystore)

### Why it exists

`flutter_secure_storage` stores auth tokens in the iOS Keychain, which lives outside the app's data container. Replicate's container snapshots don't capture Keychain items, so login state is lost on restore without this.

### How it works

**On save (Record Session):** interceptor auto-dumps the keystore on `init()`. Replicate copies the file into the snapshot when `stopRecording()` runs. No extra app launch needed.

**On save (Quick Save):** Replicate briefly launches the app with `mode: "dump_keystore"`. Interceptor dumps the keystore. Adds ~2–3 seconds.

**On restore (Session Record → Intercept):** Replicate writes the keystore file back into `Documents/` and sets `restoreKeystore: true`. On `init()`, the interceptor restores Keychain entries, deletes the plaintext file, then activates intercept mode.

**On restore (Quick Save):** Same keystore injection, but with `mode: "restore_only"`. Interceptor restores Keychain entries then stays completely inactive — app runs normally with no interception.

If the keystore file is missing when `restoreKeystore: true`, `init()` logs a warning and continues — the app starts unauthenticated rather than crashing.

### Security considerations

- The keystore file contains **plaintext Keychain contents** — a dev-only trade-off.
- All `KeystoreManager` methods are guarded by `assert(!kReleaseMode)` + a runtime check. They are complete no-ops in release builds.
- The plaintext file is deleted immediately after restore.
- **Never ship this package in a release build.**

---

## Binary and multipart body support

Binary bodies are fully supported. The interceptor detects content-type and stores either a UTF-8 string or a base64-encoded string in the tape JSON:

| Content-type | Encoding in tape |
|---|---|
| `application/json`, `text/*`, `application/xml`, `application/x-www-form-urlencoded` | `utf8` |
| `multipart/form-data`, `image/*`, `application/octet-stream`, everything else | `base64` |

`package:http` captures `StreamedRequest` and `MultipartRequest` bodies by finalising the stream before forwarding. Dio captures `FormData` by finalising to a byte stream. Old tape files without encoding fields are treated as `utf8` — fully backwards compatible.

---

## API reference

```dart
// Activate the interceptor (call once, first in main()).
await ReplicateInterceptor.init();

// Wrap a package:http client.
http.Client ReplicateInterceptor.wrapHttpClient(http.Client client);

// Attach a Dio interceptor.
void ReplicateInterceptor.addDioInterceptor(Dio dio);

// Check status.
bool ReplicateInterceptor.isActive;
```

---

## Limitations

- **Replay cache miss:** Requests not in the tape fall through to the real network.
- **Simulator only.** The file-based session protocol requires writing to `Documents/` before app launch — only possible on the iOS Simulator.
- **Web platform not supported.** `dart:io` is unavailable on web.
- **All keystore keys captured.** `flutter_secure_storage` is a flat key-value store. All keys are dumped, including entries from third-party SDKs.

---

## Requirements

- Flutter ≥ 3.0.0 / Dart ≥ 3.0.0
- iOS Simulator (macOS host)
- [Replicate](https://canreplicate.app) macOS app

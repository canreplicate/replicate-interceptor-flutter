# simvault_interceptor

A Flutter package that automatically intercepts network traffic and streams it
to **SimVault** — a macOS tool for recording and replaying network sessions in
the iOS Simulator.

When SimVault launches your app it injects a `SIMVAULT_SESSION_ID` environment
variable. This package detects that variable, opens a local WebSocket, and
forwards every HTTP request/response pair in real time.

The interceptor is **debug-only by default** and is a complete no-op in release
builds or when `SIMVAULT_SESSION_ID` is absent, so it is safe to leave in
production code.

---

## Supported HTTP clients

| Client | How it's intercepted |
|--------|----------------------|
| `package:http` | `SimVaultInterceptor.wrapHttpClient(client)` |
| `Dio` | `SimVaultInterceptor.addDioInterceptor(dio)` |
| `dart:io HttpClient` | Automatic via `HttpOverrides.global` |

---

## Getting started

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  simvault_interceptor: ^0.1.0
```

---

## Usage

### 1. Initialise in `main()`

```dart
import 'package:simvault_interceptor/simvault_interceptor.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Reads SIMVAULT_SESSION_ID from the environment.
  // Does nothing when the variable is absent.
  await SimVaultInterceptor.init();

  runApp(const MyApp());
}
```

### 2. Wrap your HTTP clients

#### `package:http`

```dart
import 'package:http/http.dart' as http;
import 'package:simvault_interceptor/simvault_interceptor.dart';

// Returns the original client unchanged when the interceptor is inactive.
final client = SimVaultInterceptor.wrapHttpClient(http.Client());

final response = await client.get(Uri.parse('https://api.example.com/data'));
```

#### Dio

```dart
import 'package:dio/dio.dart';
import 'package:simvault_interceptor/simvault_interceptor.dart';

final dio = Dio();
SimVaultInterceptor.addDioInterceptor(dio); // no-op when inactive

final response = await dio.get('https://api.example.com/data');
```

#### `dart:io HttpClient`

No additional setup needed.  `SimVaultInterceptor.init()` installs a global
`HttpOverrides` that wraps every `HttpClient` instance created anywhere in the
app, including those inside third-party packages.

```dart
// This client is intercepted automatically after init().
final client = HttpClient();
final request = await client.getUrl(Uri.parse('https://api.example.com/data'));
final response = await request.close();
```

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIMVAULT_SESSION_ID` | — | Set by SimVault. Required to activate the interceptor. |
| `SIMVAULT_WS_PORT` | `8889` | WebSocket port used by SimVault. |

---

## WebSocket protocol

The package connects to `ws://127.0.0.1:<SIMVAULT_WS_PORT>` and sends two
message types.

### `hello` (sent once on connect)

```json
{
  "type": "hello",
  "sessionId": "<SIMVAULT_SESSION_ID>",
  "version": "1.0.0"
}
```

### `network_event` (sent per request)

```json
{
  "type": "network_event",
  "data": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "timestamp": "2024-06-01T12:00:00.000Z",
    "method": "POST",
    "url": "https://api.example.com/login",
    "requestHeaders": { "content-type": "application/json" },
    "requestBody": "{\"email\":\"user@example.com\"}",
    "statusCode": 200,
    "responseHeaders": { "content-type": "application/json" },
    "responseBody": "{\"token\":\"abc123\"}",
    "durationMs": 143,
    "isSuccess": true
  }
}
```

---

## API reference

```dart
// Activate the interceptor (call once in main()).
await SimVaultInterceptor.init({bool forceInRelease = false});

// Wrap a package:http client.
http.Client SimVaultInterceptor.wrapHttpClient(http.Client client);

// Attach a Dio interceptor.
void SimVaultInterceptor.addDioInterceptor(Dio dio);

// Temporarily pause / resume event forwarding.
SimVaultInterceptor.disable();
SimVaultInterceptor.enable();

// Check connection status.
bool SimVaultInterceptor.isActive;
```

---

## Additional notes

- **Web platform**: `dart:io` is not available on the web; this package targets
  iOS / Android / macOS / Linux / Windows Flutter targets only.
- **Reconnection**: The WebSocket client retries every 3 seconds if the
  connection drops.
- **Binary bodies**: Binary response bodies are represented as
  `<binary N bytes>` rather than being base64-encoded.

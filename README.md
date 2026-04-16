# replicate_interceptor

This package is a companion for the [Replicate App](https://canreplicate.app) — install Replicate on your Mac, add this package to your Flutter app, and you're ready to record, restore, and tamper with your iOS Simulator sessions.

---

[Replicate](https://canreplicate.app) is a macOS developer tool that lets you save and restore full iOS Simulator app state snapshots. It captures your app's data container, records all network traffic, and lets you tamper with requests and responses — so you can reproduce any app state instantly and test edge cases without touching production.

[![Replicate](https://canreplicate.app/og-image.png)](https://canreplicate.app)

This package hooks into your Flutter app's network layer. Replicate activates it on demand by writing a session config before launch. When that file is absent — normal dev runs, CI, production — every method is a **complete no-op**. Safe to leave in your codebase indefinitely.

---

## Install

```yaml
# pubspec.yaml
dev_dependencies:
  replicate_interceptor: ^0.1.0
```

---

## Setup

Call `init()` right after `WidgetsFlutterBinding.ensureInitialized()`, before anything else:

```dart
import 'package:replicate_interceptor/replicate_interceptor.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ReplicateInterceptor.init();
  runApp(const MyApp());
}
```

Then wrap your HTTP clients:

```dart
// package:http
final client = ReplicateInterceptor.wrapHttpClient(http.Client());

// Dio
ReplicateInterceptor.addDioInterceptor(dio);

// dart:io HttpClient — no setup needed, covered automatically
```

That's it. Replicate handles the rest.

---

## Requirements

- Flutter ≥ 3.0.0
- iOS Simulator (macOS host)
- [Replicate](https://canreplicate.app) macOS app

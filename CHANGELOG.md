## 0.1.0

* Initial release.
* Auto-detection via `REPLICATE_SESSION_ID` environment variable.
* `package:http` interceptor via `ReplicateInterceptor.wrapHttpClient`.
* Dio interceptor via `ReplicateInterceptor.addDioInterceptor`.
* `dart:io HttpClient` interceptor via automatic `HttpOverrides`.
* WebSocket transport to Replicate with auto-reconnect.
* Debug-only by default; `forceInRelease` escape hatch available.

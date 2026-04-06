## 0.1.0

* Initial release.
* Auto-detection via `SIMVAULT_SESSION_ID` environment variable.
* `package:http` interceptor via `SimVaultInterceptor.wrapHttpClient`.
* Dio interceptor via `SimVaultInterceptor.addDioInterceptor`.
* `dart:io HttpClient` interceptor via automatic `HttpOverrides`.
* WebSocket transport to SimVault with auto-reconnect.
* Debug-only by default; `forceInRelease` escape hatch available.

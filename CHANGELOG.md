# Changelog

## 1.4.3

- Hardened helper installation with pre-authentication snapshots and root-side SHA-256 verification to prevent checkout replacement races.
- Hardened the native connection lifecycle with bounded input, output, and total operation time.
- Added structured JSON results for helper connect/disconnect actions.
- Fixed persisted manual server selections being reset during startup.
- Improved streaming-service and server-inventory error reporting.
- Added root-helper version drift detection; rerun `install-helper.sh` after plugin updates.
- Added strict TLS endpoint pinning, safer privileged CLI environment handling, and rollback-aware disconnect cleanup.
- Added Python, shell, and QML validation to CI.

## 1.4.2

- See the repository history for the 1.4.2 release changes.

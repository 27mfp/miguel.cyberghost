# 1.6.1 candidate — release gates

This is not yet a fully verified stable release. Do not label mocked tests or a vendor exit code as proof of a working VPN.

## Verified

- [x] 101 Python tests pass on Python 3.9, 3.12 and the local interpreter.
- [x] The setup wrapper's real-PTY test verifies Enter/No behavior and hidden password input.
- [x] Vendor account configuration is present and server discovery works: Lisbon traffic instances and US streaming profiles were fetched.
- [x] Existing native device credentials were preserved separately before vendor setup; their bytes remained unchanged afterward.
- [x] Native connect, IPv4/IPv6 route selection, uncached VPN DNS and disconnect cleanup passed on the earlier 1.6.0 helper.
- [x] A live OpenVPN test reproduced the vendor returning zero while disconnected. The 1.6.1 helper now rejects that case, attempts cleanup and reports the failure.
- [x] Regression tests cover supported OpenVPN UDP/TCP arguments, missing/unrecognized vendor status, failed activation, timeout cleanup and unsuccessful disconnect.
- [x] Helper capability 7 rejects older helpers that lack those checks.

## Still required before a stable release

- [ ] Complete an independent code/security review using the selected Grok model. The review runner has been blocked by Pi runtime/dependency errors; no completed independent audit is claimed.
- [ ] Resolve the installed vendor/OpenVPN compatibility problem without disabling TLS verification or silently changing system sudo policy.
- [ ] Successful OpenVPN UDP and TCP connections, observed routes/DNS, and cleanup after each.
- [ ] Live torrent and streaming-mode connections on supported servers. Listing profiles is not proof that a streaming service can be accessed.
- [ ] Recheck native WireGuard with helper 1.6.1 and the preserved device credentials.
- [ ] Controlled activation failure and timeout recovery, including residual routes, DNS, processes and original IPv6 settings.
- [ ] Concurrent requests from multiple monitor widgets, owner re-election/hotplug and constrained-height UI checks.
- [ ] Clean install, upgrade, disable/re-enable and removal in a disposable environment.
- [ ] Run the complete final gates, review the exact release diff, then push and inspect remote CI before tagging or advertising stability.

## OpenVPN investigation

The installed vendor CLI is 1.4.1 and OpenVPN is 2.7.6. The vendor prints “VPN connection failed” but exits zero; its generated log was empty. Installed vendor code invokes `sudo openvpn` and captures the child's error stream without displaying it in the generic failure path.

OpenVPN 2.7.6 rejects `--ncp-disable`. The Arch package supplies an OpenVPN wrapper that strips this obsolete option. Whether nested sudo bypasses that wrapper is being checked; the rejected option alone is not yet proof of the exact live failure cause.

No sudoers change, certificate replacement, device deletion or passwordless authorization has been applied as a workaround. The plugin provides no kill switch. Vendor process presence does not establish routing, DNS or leak protection.

## Summary

<!-- What changed and which boundary does it affect? -->

## Checklist

- [ ] `python3 -m pytest -q` passes
- [ ] `ruff check .` and `ruff format --check .` pass
- [ ] `mypy` passes
- [ ] `bash scripts/test-qml.sh` passes
- [ ] `python3 scripts/check_manifest.py` passes
- [ ] Shell scripts pass `bash -n`, `shellcheck` and `shfmt -i 2 -ci -d`
- [ ] No credentials, tokens, account identifiers or public IPs in the diff or screenshots
- [ ] Public contracts preserved: CLI, JSON actions, IPC names, `manifest.json`
- [ ] Docs updated (`README.md`, `docs/architecture.md`, `INSTALLER.md`, `CHANGELOG.md` as needed)

## Validation notes

<!-- Live VPN, routing/DNS or real-shell checks still required, with redacted evidence. -->

## Related issues

Closes #

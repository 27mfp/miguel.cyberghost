# Contributing

Thanks for helping improve CyberGhost VPN for Omarchy. This is a QML plugin
with a small Python backend; both are tested without a live VPN account.

## Requirements

- Omarchy (the QML suite targets the installed shell's Qt version)
- Python 3.9+ for the backend
- `ruff`, `mypy`, `pytest`, `shellcheck` (see `requirements-dev.txt`)
- Qt 6 tools in `/usr/lib/qt6/bin` (override with `QT_BIN`)

## Local setup

```bash
git clone https://github.com/27mfp/miguel.cyberghost.git
cd miguel.cyberghost
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
```

## Checks before a pull request

Run the same gates as CI:

```bash
python3 -m pytest -q
ruff check .
ruff format --check .
mypy
bash scripts/test-qml.sh
python3 scripts/check_manifest.py
python3 scripts/check_qml.py          # needs the installed Omarchy shell
python3 scripts/sync-preview.py --check
shellcheck install.sh fresh-install.sh scripts/*.sh
shfmt -i 2 -ci -d install.sh fresh-install.sh scripts/*.sh
git diff --check
```

`scripts/check_qml.py` maps `qs` to the installed Omarchy imports and fails on
new project diagnostics. Its allowlist is for known host metadata only; do not
broaden it to hide a plugin typo.

## Layout

- `BarWidget.qml` is the manifest entry point. The other root-level QML files
  are its panel, components and `Service.qml`.
- `Countries.js` is the UI country table; `cyberghost/constants.py` is the
  backend city table. `tests/test_contracts.py` enforces that they stay in
  sync (plus the documented `UK → GB` alias).
- `cyberghost_runner.py` is the stable CLI entry point. The implementation is
  the `cyberghost/` package, split by domain. Keep the facade contract: tests
  and `Service.qml` call `cyberghost_runner.py` and patch its module
  attributes.
- `install.sh` owns guided setup, `--fresh`, `--uninstall` and `--dry-run`.
  `fresh-install.sh` is a deprecated wrapper; add new behaviour to
  `install.sh`.
- Historical audit reports live in `docs/audits/`.

## Conventions

- QML: 2-space indentation, `qmlformat` parse-clean, host controls from
  `qs.Ui`/`qs.Commons`. Never add a privileged command without documenting the
  authorization model.
- Python: 120 columns, `ruff` lint/format, type-checked with `mypy`. Keep
  subprocesses bounded and validated; remote data never reaches argv untyped.
- Shell: 2-space indentation, `shfmt -i 2 -ci`, `shellcheck` clean, absolute
  paths for privileged binaries, prompts that fail closed on EOF.
- Tests: prefer behaviour and contracts over source-text assertions. Add a
  regression for each bug fix; if a test needs sudo, a live VPN or an account,
  it belongs in the release checklist instead.
- Commits: one logical change per commit, imperative subject. Mention the
  affected boundary (backend, QML, installer, CI, docs).

## Marketplace checks

The `Marketplace` workflow runs the Omarchy plugin marketplace's own update
validation and automated security baseline (from
`omacom/omarchy-plugin-marketplace`) on every push, pull request and release
tag. It fails when the commit would not be accepted as is:

- marketplace compatibility validation fails;
- the security baseline reports any finding (for example
  `remote-git-execution-unpinned` or `curl-pipe-shell`); fix the code rather
  than asking a maintainer to accept it;
- the baseline detects a capability that is not listed in
  `.github/marketplace/allowed-capabilities.json`. Add one only after deciding
  it is intended, and say why in the pull request.

To check a pushed commit locally (`npm ci --ignore-scripts` in a marketplace
clone first):

```bash
GITHUB_TOKEN=$(gh auth token) node .github/marketplace/check.mjs \
  --marketplace=../omarchy-plugin-marketplace --plugin-id=miguel.cyberghost \
  --repo=https://github.com/27mfp/miguel.cyberghost --commit="$(git rev-parse HEAD)" \
  --allowed-capabilities=.github/marketplace/allowed-capabilities.json
```

After the release commit is on the default branch, open a
[Plugin verification](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=verify-plugin.yml)
request for that exact SHA.

## Security

Read `SECURITY.md` before reporting or changing credential, IPC or
NetworkManager code. Do not include real tokens, JWTs or account details in
tests, fixtures, issues or screenshots.

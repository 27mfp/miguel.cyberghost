# Installer guide

The repository ships three shell installers. Pick the one that matches the
task; they are not interchangeable.

| Script | When to use | Touches the system? | Re-runnable? |
|---|---|---|---|
| `install.sh` | First-time setup after `omarchy plugin add`. Walks through pacman packages, the AUR CLI, account linking, and the root helper. | Yes (asks before each step) | Yes — every step is gated by a `Y/n` prompt and skips work that is already done. |
| `install-helper.sh` | Re-install **just** the root helper and (optionally) the Polkit rule, after a plugin update that changed `cyberghost_runner.py` or the Polkit rule. | Yes — uses `sudo` in a visible terminal. | Yes. Pass `--no-polkit-rule` (or `--helper-only`) to skip the optional Polkit rule. |
| `fresh-install.sh` | **Developer-only.** Wipes the plugin, helper, rule, and account state, then reinstalls from GitHub (or from the local checkout) to simulate a brand-new user. | Destructive by design. | Use it after a non-trivial change to confirm a new user lands on a working setup. |

## Re-installing the helper after a plugin update

Every release that touches `cyberghost_runner.py` (the Python root helper) is
**required** to re-run `install-helper.sh` from a visible terminal:

```bash
bash ~/.config/omarchy/plugins/miguel.cyberghost/install-helper.sh
```

The widget surfaces a **"helper version drift"** warning when the on-disk
helper is older than the bundled one, and the FIRST-RUN SETUP panel keeps
showing the helper item until the re-install completes.

## Picking the right option for the Polkit rule

The Polkit rule (granted to `wheel`) is **opt-in**. Default: install it.
Override with `--no-polkit-rule` (or `--helper-only`) when:

- The machine is shared and `wheel` membership is not strictly controlled.
- You prefer to type the sudo password every time you connect or disconnect.

Without the rule, `pkexec` still gates each connect/disconnect with a
graphical authorization dialog.

## CI does not run these scripts

`install.sh`, `install-helper.sh`, and `fresh-install.sh` are user-facing
installers and require an interactive terminal (they prompt, ask for sudo,
and shell out to package managers). CI only validates their syntax with
`bash -n` and `shellcheck`. A successful `pytest`, `ruff`, `qmllint`, and
`qmlformat` run is the gate for merge.

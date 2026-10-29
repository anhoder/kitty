# Ghostty versus kitty: macOS shell startup latency

Date: 2026-10-29

## Finding

Ghostty is faster mainly because it performs the shell setup inside the already-running Ghostty process and then launches the macOS login chain directly. kitty launches an additional `kitten run-shell` executable for the default shell on macOS. The extra executable startup is the dominant measured difference on this workstation.

## kitty path

For a default shell on macOS, kitty marks the child as requiring the `run-shell` kitten (`kitty/child.py:364-365`). In `Child.fork`, kitty changes the command to:

```text
kitten run-shell --shell '<shell>' --shell-integration '<settings>'
```

and then wraps it with:

```text
/usr/bin/login -f -l -p <user> kitten run-shell ...
```

Source: https://github.com/kovidgoyal/kitty/blob/master/kitty/child.py

`kitten run-shell` then performs shell-integration/terminfo setup and execs the shell:

- `tools/cmd/run_shell/main.go:79-125`
- `tools/tui/run.go:163-200`
- `tools/tui/shell_integration/api.go:358-367`

Local measurements using the installed kitty 0.49.2 executable, with `TERM=dumb` to avoid an unrelated terminal capability probe:

| Path | Observed wall time |
|---|---:|
| direct fish startup | 0.08–0.09 s |
| `kitten run-shell --shell=/opt/homebrew/bin/fish` | 1.34–1.52 s |
| `kitten --version` | about 1.29 s |
| `/usr/bin/login` + `kitten run-shell` + fish | about 2.48 s in the PTY probe |

Disabling kitty shell integration did not remove the overhead: `kitten run-shell --shell-integration disabled` was still about 1.44 s. This isolates the dominant cost to starting the kitten launcher/process, not fish integration code.

## Ghostty path

Ghostty builds the child argv and environment in its main process. `src/termio/Exec.zig` calls `execCommand` before spawning the PTY child, and the shell integration setup modifies the environment/argv in-process:

- `Subprocess.init` calls `shell_integration.setup(...)` and then `execCommand(...)`.
- Fish integration prepends Ghostty's integration directory to `XDG_DATA_DIRS`; fish auto-loads the vendor configuration on startup.
- Source: https://github.com/ghostty-org/ghostty/blob/main/src/termio/Exec.zig
- Source: https://github.com/ghostty-org/ghostty/blob/main/src/termio/shell_integration.zig
- Developer notes: https://github.com/ghostty-org/ghostty/blob/main/src/shell-integration/README.md

Ghostty still honors macOS login-shell behavior. Its current Darwin `execCommand` path constructs:

```text
/usr/bin/login [-q] -flp <user> /bin/bash --noprofile --norc -c 'exec -l <shell>'
```

The intermediate bash is intentionally started without startup files and immediately `exec`s the requested shell. Ghostty's source comments state that this preserves macOS login behavior, `getlogin()`, `$SHELL`, working directory, and `.hushlogin` semantics. It also says that bash was selected because a microbenchmark found bash can exec into the target shell about twice as fast as zsh.

Relevant source ranges in the current `Exec.zig`:

- `execCommand`: approximately lines 1836–1963
- Darwin login rationale: approximately lines 1855–1924
- `/usr/bin/login`, `-flp`, and bash `exec -l`: approximately lines 1939–1963

Ghostty docs confirm the intended behavior:

- macOS shells are started as login shells: https://ghostty.org/docs/help/macos-login-shells
- Ghostty automatically injects shell integration for fish and other supported shells: https://ghostty.org/docs/features/shell-integration

## Why Ghostty avoids the visible delay

Both applications need to deal with macOS login-shell behavior. The key difference is the process graph:

```text
kitty:   kitty -> /usr/bin/login -> kitten run-shell -> fish
Ghostty: Ghostty -> /usr/bin/login -> bash -> exec fish
```

`kitten run-shell` is a separate kitty executable and must initialize its own command/runtime path before fish starts. The installed kitten launcher itself accounts for roughly 1.3 seconds in the local measurement. Ghostty performs equivalent setup in its compiled Zig process and does not introduce a separate Ghostty helper executable for each new pane.

This also explains why changing only `shell_integration` is not sufficient in kitty: kitty's macOS default-shell decision to run through `kitten run-shell` is separate from the integration feature flags.

## Limits

- The local GUI comparison measured command chains, not an automated GUI-level “new pane to first prompt” benchmark inside both applications.
- The Ghostty-equivalent login/bash/exec chain measured about 0.21–0.23 s locally, versus about 2.48 s for the login/kitten/fish chain. This isolates the extra kitten process as the material difference in the command path.
- Fish configuration and prompt rendering were separately measured locally and were below the observed kitty wrapper cost.

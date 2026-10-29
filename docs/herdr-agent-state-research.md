Herdr agent-state acquisition
=============================

This note records the primary-source findings used to align kitty's Agent sidebar state with Herdr.

## State authority

Herdr first identifies the foreground process, then chooses one state authority per pane. The official agent docs state that complete lifecycle integrations are authoritative while active; otherwise Herdr reads the live bottom-of-buffer screen and evaluates an agent-specific TOML manifest. Session-only integrations do not replace screen detection. Sources:

- <https://herdr.dev/docs/agents/> — “Status authority”, blocked-state safety, live bottom-buffer semantics.
- `src/detect/mod.rs` — `foreground_job`, `identify_agent_process_in_job`, `detect_agent_with_osc`.
- `src/terminal/state.rs` — `HookAuthority`, fallback state, effective-state arbitration.
- `src/integration/mod.rs` — full-lifecycle integration allowlist and integration assets.

The important distinction: process identity answers “which Agent is in this pane”; it does not answer “what is the Agent doing”.

## Screen detection

Herdr's screen path is manifest-driven:

1. Read the live terminal tail, not user-scrolled history.
2. Optionally include OSC title/progress strings.
3. Select the loaded manifest for the detected Agent.
4. Evaluate every rule against a named region.
5. Choose the highest-priority matching rule.
6. Publish `idle`, `working`, `blocked`, or `unknown`, plus visible-evidence flags.
7. If no rule matches for a known Agent, use `idle` with `default_known_agent_idle_fallback`.

Primary sources:

- `src/detect/manifest.rs` — `DetectionInput`, `ManifestRule`, `ManifestGate`, `evaluate_loaded_manifest`, `region`, `fallback_explain`.
- `src/detect/manifest/tests.rs` — priority, nested all/any/not gates, line regex, bottom-buffer/footer anchoring, stale-output rejection.
- `src/detect/manifests/opencode.toml` — permission blocker, interrupt-hint working, progress-bar working.
- `src/detect/manifests/claude.toml` — spinner/title working, live-turn working, background-task working, transcript-viewer skip, permission blockers, prompt-box idle.
- `src/detect/manifests/codex.toml` — title spinner/action-required, transcript viewer skip, trust/startup blockers, timer-based working, weak blockers, idle title.

Herdr does not classify arbitrary screen churn as working. Working requires a manifest-owned visible marker such as a spinner, interrupt hint, progress bar, or timer. Blocked requires visible approval/question UI. Unknown is used for transcript viewers and other screens where changing state would be unsafe.

## Stabilization

Herdr avoids flicker and unsafe transitions in `src/pane/agent_detection.rs`:

- `PendingIdleConfirmation` holds a working→plain-idle transition for three 100ms confirmations, capped at 700ms.
- Visible idle/blocker evidence bypasses that hold.
- `STABLE_VISIBLE_SIGNAL_REFRESH` is 800ms for repeated visible blocker signals.
- `AGENT_STARTUP_GRACE_WINDOW` is 3s for initial process acquisition.
- Screen content changes are tracked separately from raw PTY bytes.
- Unchanged idle bottom buffers can skip screen reads; identified Agents continue their normal detection reads.

## Kitty delta and implementation choice

Kitty already has an equivalent semantic channel: OSC 7501 in `kitty/program_status.py`, including bounded records, `working`/`blocked`/`done` states, process-exit cleanup, and watcher callbacks. Kitty lacks Herdr's manifest engine, so the implementation adds a small in-process manifest-style matcher for the high-value Agents and uses conservative idle fallback for unmatched screens.

The matcher must:

- inspect only the current screen tail;
- evaluate explicit Agent rules with priority;
- distinguish visible idle, visible working, and visible blocked markers;
- never infer working from generic screen churn;
- let OSC 7501 override screen fallback;
- keep the existing dirty-window tracker and event-driven refresh path.

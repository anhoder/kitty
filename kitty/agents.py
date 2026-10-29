#!/usr/bin/env python
# License: GPLv3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

import os
import time
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from enum import Enum
from typing import Any

from .agent_manifest import ManifestState, Screen, StateAuthority, authority_for, detect
from .fast_data_types import monotonic


class AgentState(str, Enum):
    idle = 'idle'
    working = 'working'
    blocked = 'blocked'
    done = 'done'
    unknown = 'unknown'


# Manifest rules never assert done: that is a lifecycle outcome reported over
# OSC 7501, not something visible on screen.
STATE_MAP = {
    ManifestState.idle: AgentState.idle,
    ManifestState.working: AgentState.working,
    ManifestState.blocked: AgentState.blocked,
    ManifestState.unknown: AgentState.unknown,
}


@dataclass(frozen=True)
class AgentSnapshot:
    window_id: int
    agent: str
    state: AgentState
    title: str
    cwd: str


@dataclass(frozen=True)
class AgentSidebarRow:
    window_id: int
    group: str
    agent: str
    title: str
    detail: str
    state: AgentState
    is_active: bool

# Maps a foreground executable name to a manifest id. The value side must match
# the manifest `id` field, because that is the key the rule tables are looked
# up under. An unrecognized foreground process is still a normal terminal, not
# an unknown agent row.
AGENT_EXECUTABLES: dict[str, str] = {
    'amp': 'amp',
    'agy': 'agy',
    'antigravity': 'agy',
    'claude': 'claude',
    'cline': 'cline',
    'codex': 'codex',
    'copilot': 'copilot',
    'cursor-agent': 'cursor',
    'devin': 'devin',
    'droid': 'droid',
    'gemini': 'gemini',
    'grok': 'grok',
    'hermes': 'hermes',
    'kimi': 'kimi',
    'kiro': 'kiro',
    'kiro-cli': 'kiro',
    'kilo': 'kilo',
    'letta': 'letta',
    'maki': 'maki',
    'mastracode': 'mastracode',
    'muse': 'muse',
    'omp': 'omp',
    'opencode': 'opencode',
    'pi': 'pi',
    'qoder': 'qodercli',
    'qodercli': 'qodercli',
    'qwen': 'qwen',
}


def _executable_name(value: str) -> str:
    name = os.path.basename(value).lower()
    if name.endswith(('.cmd', '.exe')):
        name = name.rsplit('.', 1)[0]
    return name


def _candidate_names(process: Mapping[str, Any]) -> Sequence[str]:
    cmdline = process.get('cmdline')
    if not cmdline:
        return ()
    names = [_executable_name(str(cmdline[0]))]
    if names[0] in {'env', 'node', 'bun', 'deno', 'python', 'python3', 'ruby', 'java'} and len(cmdline) > 1:
        names.append(_executable_name(str(cmdline[1])))
    return tuple(names)


def detect_agent(processes: Sequence[Mapping[str, Any]]) -> str | None:
    """Return the first recognized foreground agent, if any."""
    for process in processes:
        for candidate in _candidate_names(process):
            if candidate in AGENT_EXECUTABLES:
                return AGENT_EXECUTABLES[candidate]
    return None


def state_from_signals(
    agent: str | None,
    program_status: Sequence[Mapping[str, Any]],
    screen: Screen | None = None,
    previous: AgentState | None = None,
) -> AgentState:
    """Arbitrate a semantic report against visible screen evidence."""
    return arbitrate(agent, program_status, screen, previous)[0]


def arbitrate(
    agent: str | None,
    program_status: Sequence[Mapping[str, Any]],
    screen: Screen | None = None,
    previous: AgentState | None = None,
) -> tuple[AgentState, bool]:
    """Return the state plus whether a visible idle marker backs it.

    A reported state only wins for agents whose integration covers the whole
    lifecycle. An integration that only reports session identity has no
    handler for cancellations and interrupts, so its last report goes stale
    and would otherwise pin the pane to a state the screen contradicts.
    """
    if agent is None:
        return AgentState.unknown, False
    reported = _reported_state(program_status)
    if reported is not None and authority_for(agent) is StateAuthority.full_lifecycle:
        return reported, False
    match = detect(agent, screen) if screen is not None else None
    if match is None or match.manifest is None:
        # We recognize the process but ship no rules for it, so we cannot see
        # what it is doing. Claiming idle would be a guess that reads as fact;
        # unknown is the truth.
        return reported or AgentState.unknown, False
    if match.skipped:
        # A transcript viewer or menu overlay has replaced the live UI; it says
        # nothing about what the agent is doing, so hold what we had.
        held = previous if previous is not None else (reported or AgentState.unknown)
        return held, False
    if match.rule is None:
        # Rules exist and none matched. For an identified agent that means at
        # rest, not working: working requires a visible marker.
        return reported or AgentState.idle, False
    return STATE_MAP[match.state], match.visible_idle


def _reported_state(program_status: Sequence[Mapping[str, Any]]) -> AgentState | None:
    states = {str(record.get('state', '')) for record in program_status}
    if 'blocked' in states:
        return AgentState.blocked
    if 'error' in states or 'done' in states:
        return AgentState.done
    if 'working' in states:
        return AgentState.working
    if 'idle' in states:
        return AgentState.idle
    return None


def snapshot_for_window(
    window: Any, screen: Screen | None = None, previous: AgentState | None = None
) -> tuple[AgentSnapshot | None, bool]:
    agent = detect_agent(window.child.foreground_processes)
    if agent is None:
        return None, False
    state, visible_idle = arbitrate(agent, window.program_status.as_list(), screen, previous)
    snapshot = AgentSnapshot(
        window_id=window.id,
        agent=agent,
        state=state,
        title=window.title,
        cwd=window.cwd_of_child or window.child.cwd,
    )
    return snapshot, visible_idle


class AgentTracker:
    """Cache per-window agent snapshots and coalesce event-driven refreshes.

    Also holds back one specific transition: working to a plain idle that has
    no visible idle marker behind it. Agent TUIs repaint their status area in
    several steps, so for a frame or two mid-turn the working marker is gone
    while the prompt box has not been drawn yet. Publishing idle there makes
    the sidebar flicker. A transition backed by visible evidence, and every
    other transition, applies immediately.
    """

    IDLE_DEBOUNCE = 0.25

    def __init__(self) -> None:
        self.snapshots: dict[int, AgentSnapshot | None] = {}
        self.dirty_windows: set[int] = set()
        self.pending_idle_since: dict[int, float] = {}
        # Windows whose turn finished while the user was looking elsewhere.
        self.unseen_done: set[int] = set()

    def mark_dirty(self, window_id: int) -> None:
        self.dirty_windows.add(window_id)

    def mark_all_dirty(self, window_ids: Sequence[int]) -> None:
        self.dirty_windows.update(window_ids)

    def drain_dirty(self) -> tuple[int, ...]:
        dirty = tuple(self.dirty_windows)
        self.dirty_windows.clear()
        return dirty

    def refresh_window(self, window: Any, now: float | None = None) -> bool:
        previous = self.snapshots.get(window.id)
        previous_state = previous.state if previous is not None else None
        screen = window.agent_detection_snapshot()
        current, visible_idle = snapshot_for_window(window, screen, previous_state)
        if current is not None and previous is not None:
            current = self._debounce_idle(current, previous, visible_idle, now if now is not None else monotonic())
            current = self._hold_done(current, previous, window)
        else:
            self.pending_idle_since.pop(window.id, None)
            self.unseen_done.discard(window.id)
        self.snapshots[window.id] = current
        return previous != current

    def _debounce_idle(self, current: AgentSnapshot, previous: AgentSnapshot, visible_idle: bool, now: float) -> AgentSnapshot:
        going_quiet = previous.state is AgentState.working and current.state is AgentState.idle
        if not going_quiet or visible_idle:
            self.pending_idle_since.pop(current.window_id, None)
            return current
        since = self.pending_idle_since.setdefault(current.window_id, now)
        if now - since >= self.IDLE_DEBOUNCE:
            self.pending_idle_since.pop(current.window_id, None)
            return current
        return previous

    def _hold_done(self, current: AgentSnapshot, previous: AgentSnapshot, window: Any) -> AgentSnapshot:
        """Turn a finished turn into done, and keep it until the user looks.

        A screen-detected agent has no way to report completion, so the
        transition out of working is the only evidence a turn ended. Showing
        idle there loses the one piece of information the user wants after
        stepping away: this agent finished while you were not watching.
        """
        if window.is_focused:
            # Looking at the window is seeing it.
            self.unseen_done.discard(current.window_id)
            return current
        if previous.state is AgentState.working and current.state is AgentState.idle:
            self.unseen_done.add(current.window_id)
        if current.window_id in self.unseen_done and current.state is AgentState.idle:
            return replace(current, state=AgentState.done)
        if current.state not in (AgentState.idle, AgentState.done):
            # Started working again, or is now blocked: the completion is no
            # longer the latest thing that happened.
            self.unseen_done.discard(current.window_id)
        return current

    def discard(self, window_id: int) -> None:
        self.dirty_windows.discard(window_id)
        self.snapshots.pop(window_id, None)
        self.pending_idle_since.pop(window_id, None)
        self.unseen_done.discard(window_id)

    def snapshot_for(self, window_id: int) -> AgentSnapshot | None:
        return self.snapshots.get(window_id)



def state_icon(state: AgentState) -> str:
    return {
        AgentState.blocked: '●',
        AgentState.working: '⟳',
        AgentState.done: '✓',
        AgentState.idle: '·',
        AgentState.unknown: '?',
    }[state]

def state_code(state: AgentState) -> int:
    return {
        AgentState.unknown: 0,
        AgentState.idle: 1,
        AgentState.working: 2,
        AgentState.blocked: 3,
        AgentState.done: 4,
    }[state]

def session_group_for_window(window: Any) -> str:
    age_ns = max(0, time.time_ns() - int(window.created_at))
    if age_ns < 24 * 60 * 60 * 1_000_000_000:
        return 'Today'
    if age_ns < 48 * 60 * 60 * 1_000_000_000:
        return 'Yesterday'
    return 'Earlier'

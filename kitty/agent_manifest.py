#!/usr/bin/env python
# License: GPLv3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

"""Manifest-driven agent state detection.

This is a re-implementation of the detection model used by herdr
(https://herdr.dev, Apache-2.0). The manifest files in :file:`agent_manifests/`
are derived from herdr's published agent-detection manifests.

The model has three parts:

region
    A named slice of the pane. A rule only ever matches inside one region, so
    text from an unrelated part of the screen cannot trigger it.
gate
    A boolean expression over the region text, built from ``contains``,
    ``regex``, ``line_regex`` and the ``all``/``any``/``not`` combinators.
rule
    A region plus a gate plus the state to publish, ordered by ``priority``.

Every rule is evaluated and the highest-priority match wins. This matters:
short-circuiting on the first match makes the declaration order significant and
makes the outcome depend on how the file happens to be written.
"""

import os
import re
import tomllib
from collections.abc import Iterable, Iterator, Mapping, Sequence
from enum import Enum
from functools import lru_cache
from typing import Any, NamedTuple

from .constants import kitty_base_dir
from .utils import log_error

MANIFEST_DIR = os.path.join(kitty_base_dir, 'kitty', 'agent_manifests')


class ManifestState(Enum):
    idle = 'idle'
    working = 'working'
    blocked = 'blocked'
    unknown = 'unknown'


class StateAuthority(Enum):
    """Who decides the state when a semantic report and the screen disagree.

    herdr only lets an agent's own lifecycle reports win when its integration
    covers the whole lifecycle. For agents whose hooks only report session
    identity, a reported state is discarded outright rather than being allowed
    to win and then be corrected, because an incomplete hook goes stale on
    cancellation and interrupt paths and then pins the pane to a wrong state.
    """

    full_lifecycle = 'full_lifecycle'
    identity_only = 'identity_only'


# The manifests are written for Rust's regex crate. Three of its constructs
# have no Python spelling and must be rewritten; the rest of what the
# manifests use (inline flags, \z, character classes) is already compatible,
# and the crate has no backreferences or lookaround so nothing else can
# appear.
_rust_codepoint = re.compile(r'\\(?:x|u)\{([0-9A-Fa-f]{1,6})\}')
_rust_short_u = re.compile(r'\\u([0-9A-Fa-f]{4})')
# \p{Alphabetic} has no equivalent in re. [^\W\d_] covers every alphabetic
# code point; it additionally admits numeric-category symbols such as ² and ½,
# which cannot change the outcome of the rules that use it (they require an
# alphabetic run inside an activity label).
_rust_classes = {
    r'\p{Alphabetic}': r'[^\W\d_]',
    r'\p{L}': r'[^\W\d_]',
    r'\p{Letter}': r'[^\W\d_]',
}


def translate_regex(pattern: str) -> str:
    def codepoint(m: 're.Match[str]') -> str:
        return re.escape(chr(int(m.group(1), 16)))

    for rust, py in _rust_classes.items():
        pattern = pattern.replace(rust, py)
    pattern = _rust_codepoint.sub(codepoint, pattern)
    return _rust_short_u.sub(codepoint, pattern)


def compile_regex(pattern: str) -> 're.Pattern[str]':
    return re.compile(translate_regex(pattern))


class Region(NamedTuple):
    """A resolved region: its text plus whether it exists at all.

    ``present`` is not the same as a non-empty ``text``. A pane with no prompt
    box has no ``prompt_box_body`` region, and a rule scoped to it must not
    match; matching against an empty string instead would let a ``not`` gate
    pass vacuously.
    """

    text: str
    present: bool

    @property
    def lines(self) -> list[str]:
        return self.text.splitlines()


MISSING = Region('', False)


class Screen(NamedTuple):
    """The detection snapshot: what the agent is showing right now.

    ``lines`` is the live bottom of the pane, independent of how far the user
    has scrolled back, and keeps blank lines because the region vocabulary
    counts *non-empty* lines and needs to see which lines are blank.
    """

    lines: tuple[str, ...]
    title: str = ''
    progress: str = ''

    @classmethod
    def from_text(cls, text: str, title: str = '', progress: str = '') -> 'Screen':
        return cls(tuple(text.splitlines()), title, progress)


# Prompt boxes are drawn with rounded box-drawing corners by every agent whose
# manifest refers to a prompt box.
BOX_TOP = '\u256d\u250c'  # ╭ ┌
BOX_BOTTOM = '\u2570\u2514'  # ╰ └
BOX_SIDE = '\u2502\u2503\u2506\u2507\u254e\u254f\u2551\u2590\u258c'  # │ ┃ ╎ ╏ ║ ▐ ▌
HORIZONTAL = '\u2500\u2501\u2504\u2505\u2508\u2509\u254c\u254d'
# Column-zero markers an agent renders in front of its input line.
PROMPT_MARKERS = '\u203a\u276f>\u276d\u27e9'  # › ❯ > ❭ ⟩


def _non_empty(lines: Sequence[str]) -> list[int]:
    return [i for i, line in enumerate(lines) if line.strip()]


def _join(lines: Sequence[str]) -> Region:
    return Region('\n'.join(lines), True)


def _strip_box_sides(line: str) -> str:
    """Remove a prompt box's left and right borders from one of its rows.

    Rules scoped to the box body anchor on what the user typed, e.g. ``^\\s*❯``
    for an empty Claude prompt. Leaving the border in place would push every
    marker off column zero and no such rule could ever match.
    """
    body = line.strip()
    if body and body[0] in BOX_SIDE:
        body = body[1:]
    if body and body[-1] in BOX_SIDE:
        body = body[:-1]
    return body.strip()


def _is_horizontal_rule(line: str) -> bool:
    stripped = line.strip()
    if len(stripped) < 3:
        return False
    return all(ch in HORIZONTAL or ch.isspace() for ch in stripped) and any(ch in HORIZONTAL for ch in stripped)


def _find_prompt_box(lines: Sequence[str]) -> tuple[int, int] | None:
    """Return (top, bottom) indices of the last prompt box, if any.

    Scans upward for a bottom border, then upward again for its top border, so
    a transcript containing earlier boxes resolves to the live one.
    """
    bottom = None
    for i in range(len(lines) - 1, -1, -1):
        stripped = lines[i].lstrip()
        if stripped and stripped[0] in BOX_BOTTOM:
            bottom = i
            break
    if bottom is None:
        return None
    for i in range(bottom - 1, -1, -1):
        stripped = lines[i].lstrip()
        if stripped and stripped[0] in BOX_TOP:
            return i, bottom
    return None


def _find_prompt_marker(lines: Sequence[str]) -> int | None:
    """Index of the live prompt marker line, searching upward."""
    for i in range(len(lines) - 1, -1, -1):
        stripped = lines[i].lstrip()
        if stripped and stripped[0] in PROMPT_MARKERS:
            return i
    return None


_region_arg = re.compile(r'^([a-z_]+)\((\d+)\)$')


def resolve_region(name: str, screen: Screen) -> Region:
    m = _region_arg.match(name)
    if m is not None:
        kind, count = m.group(1), int(m.group(2))
        lines = screen.lines
        if kind == 'bottom_non_empty_lines':
            idx = _non_empty(lines)[-count:]
            return _join([lines[i] for i in idx]) if idx else Region('', True)
        if kind == 'top_non_empty_lines':
            idx = _non_empty(lines)[:count]
            return _join([lines[i] for i in idx]) if idx else Region('', True)
        if kind == 'bottom_lines':
            return _join(lines[-count:])
        return MISSING

    if name == 'whole_recent':
        return _join(screen.lines)
    if name == 'osc_title':
        return Region(screen.title, bool(screen.title))
    if name == 'osc_progress':
        return Region(screen.progress, bool(screen.progress))

    lines = screen.lines
    if name == 'after_last_horizontal_rule':
        for i in range(len(lines) - 1, -1, -1):
            if _is_horizontal_rule(lines[i]):
                return _join(lines[i + 1 :])
        return MISSING
    if name == 'prompt_box_body':
        box = _find_prompt_box(lines)
        if box is None:
            return MISSING
        return _join([_strip_box_sides(line) for line in lines[box[0] + 1 : box[1]]])
    if name == 'last_non_empty_above_prompt_box':
        box = _find_prompt_box(lines)
        if box is None:
            return MISSING
        for i in range(box[0] - 1, -1, -1):
            if lines[i].strip():
                return Region(lines[i], True)
        return MISSING
    if name == 'after_last_prompt_marker':
        marker = _find_prompt_marker(lines)
        if marker is None:
            return MISSING
        return _join(lines[marker + 1 :])
    if name == 'before_current_prompt_marker':
        marker = _find_prompt_marker(lines)
        if marker is None:
            return MISSING
        return _join(lines[:marker])
    if name == 'whole_recent_without_current_prompt_marker':
        marker = _find_prompt_marker(lines)
        if marker is None:
            return _join(lines)
        return _join([line for i, line in enumerate(lines) if i != marker])
    return MISSING


KNOWN_REGIONS = frozenset(
    (
        'whole_recent',
        'whole_recent_without_current_prompt_marker',
        'prompt_box_body',
        'last_non_empty_above_prompt_box',
        'after_last_horizontal_rule',
        'after_last_prompt_marker',
        'before_current_prompt_marker',
        'osc_title',
        'osc_progress',
    )
)
KNOWN_REGION_FUNCTIONS = frozenset(('bottom_non_empty_lines', 'top_non_empty_lines', 'bottom_lines'))


def is_known_region(name: str) -> bool:
    m = _region_arg.match(name)
    if m is not None:
        return m.group(1) in KNOWN_REGION_FUNCTIONS
    return name in KNOWN_REGIONS


class Gate:
    """A boolean expression over one region's text.

    Sibling fields are ANDed, ``contains`` requires every substring, and
    ``regex``/``line_regex`` lists are satisfied by any one pattern.

    ``contains`` is case-insensitive. The manifests rely on this: Claude's
    permission rule looks for ``do you want to proceed?`` while Claude Code
    renders "Do you want to proceed?". Patterns that do need case sensitivity
    use ``regex`` and omit ``(?i)``.
    """

    __slots__ = ('contains', 'regexes', 'line_regexes', 'all_of', 'any_of', 'none_of')

    def __init__(self, spec: Mapping[str, Any], where: str) -> None:
        self.contains: tuple[str, ...] = tuple(s.lower() for s in _as_list(spec.get('contains'), str, where, 'contains'))
        self.regexes = tuple(compile_regex(p) for p in _as_list(spec.get('regex'), str, where, 'regex'))
        self.line_regexes = tuple(compile_regex(p) for p in _as_list(spec.get('line_regex'), str, where, 'line_regex'))
        self.all_of = tuple(Gate(g, where) for g in _as_list(spec.get('all'), dict, where, 'all'))
        self.any_of = tuple(Gate(g, where) for g in _as_list(spec.get('any'), dict, where, 'any'))
        self.none_of = tuple(Gate(g, where) for g in _as_list(spec.get('not'), dict, where, 'not'))

    @property
    def is_empty(self) -> bool:
        return not (self.contains or self.regexes or self.line_regexes or self.all_of or self.any_of or self.none_of)

    def matches(self, region: Region) -> bool:
        text = region.text
        if self.contains:
            folded = text.lower()
            for needle in self.contains:
                if needle not in folded:
                    return False
        if self.regexes and not any(r.search(text) for r in self.regexes):
            return False
        if self.line_regexes:
            lines = region.lines
            if not any(r.search(line) for r in self.line_regexes for line in lines):
                return False
        for gate in self.all_of:
            if not gate.matches(region):
                return False
        if self.any_of and not any(gate.matches(region) for gate in self.any_of):
            return False
        for gate in self.none_of:
            if gate.matches(region):
                return False
        return True


def _as_list(value: Any, kind: type, where: str, field: str) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, kind):
        return [value]
    if isinstance(value, list):
        for item in value:
            if not isinstance(item, kind):
                raise ValueError(f'{where}: {field} must contain only {kind.__name__}')
        return list(value)
    raise ValueError(f'{where}: {field} has invalid type {type(value).__name__}')


class Rule(NamedTuple):
    id: str
    state: ManifestState
    priority: int
    region: str
    gate: Gate
    visible_idle: bool = False
    visible_working: bool = False
    visible_blocker: bool = False
    skip_state_update: bool = False

    @property
    def has_visible_evidence(self) -> bool:
        return self.visible_idle or self.visible_working or self.visible_blocker


class Manifest(NamedTuple):
    id: str
    version: str
    authority: StateAuthority
    aliases: tuple[str, ...]
    rules: tuple[Rule, ...]


class Match(NamedTuple):
    """The outcome of evaluating a manifest, mirroring ``herdr agent explain``."""

    state: ManifestState
    rule: Rule | None
    manifest: Manifest | None
    evidence: str = ''
    skipped: bool = False

    @property
    def rule_id(self) -> str:
        return self.rule.id if self.rule is not None else 'none'

    @property
    def visible_idle(self) -> bool:
        return self.rule is not None and self.rule.visible_idle


def parse_manifest(data: Mapping[str, Any], where: str) -> Manifest:
    ident = data.get('id')
    if not isinstance(ident, str) or not ident:
        raise ValueError(f'{where}: missing id')
    version = data.get('version')
    if not isinstance(version, str) or not version:
        raise ValueError(f'{where}: manifest must include version')
    raw_authority = data.get('state_authority', StateAuthority.identity_only.value)
    try:
        authority = StateAuthority(raw_authority)
    except ValueError:
        raise ValueError(f'{where}: unknown state_authority: {raw_authority!r}') from None
    aliases = tuple(_as_list(data.get('aliases'), str, where, 'aliases'))

    rules = []
    seen: set[str] = set()
    for raw in _as_list(data.get('rules'), dict, where, 'rules'):
        rule = _parse_rule(raw, where)
        if rule.id in seen:
            raise ValueError(f'{where}: duplicate rule id: {rule.id}')
        seen.add(rule.id)
        rules.append(rule)
    # Descending priority, so evaluation can stop at the first match.
    rules.sort(key=lambda r: -r.priority)
    return Manifest(ident, version, authority, aliases, tuple(rules))


def _parse_rule(raw: Mapping[str, Any], where: str) -> Rule:
    ident = raw.get('id')
    if not isinstance(ident, str) or not ident:
        raise ValueError(f'{where}: rule missing id')
    rule_where = f'{where}: rule {ident}'
    try:
        state = ManifestState(raw.get('state'))
    except ValueError:
        raise ValueError(f'{rule_where}: unknown state: {raw.get("state")!r}') from None
    priority = raw.get('priority')
    if not isinstance(priority, int):
        raise ValueError(f'{rule_where}: priority must be an integer')
    region = raw.get('region')
    if not isinstance(region, str) or not is_known_region(region):
        raise ValueError(f'{rule_where}: uses invalid region: {region!r}')
    gate = Gate(raw, rule_where)
    if gate.is_empty:
        raise ValueError(f'{rule_where}: has no match conditions')
    return Rule(
        id=ident,
        state=state,
        priority=priority,
        region=region,
        gate=gate,
        visible_idle=bool(raw.get('visible_idle')),
        visible_working=bool(raw.get('visible_working')),
        visible_blocker=bool(raw.get('visible_blocker')),
        skip_state_update=bool(raw.get('skip_state_update')),
    )


def evaluate(manifest: Manifest, screen: Screen) -> Match:
    """Return the highest-priority matching rule.

    A match carrying ``skip_state_update`` reports ``skipped``: transcript
    viewers and menu overlays replace the live UI, so the pane's existing state
    must be held rather than recomputed from a screen that shows no activity.
    """
    cache: dict[str, Region] = {}
    for rule in manifest.rules:
        region = cache.get(rule.region)
        if region is None:
            region = cache[rule.region] = resolve_region(rule.region, screen)
        if not region.present:
            continue
        if rule.gate.matches(region):
            return Match(rule.state, rule, manifest, _evidence(region), rule.skip_state_update)
    # A known agent showing nothing we recognize is at rest, not working.
    return Match(ManifestState.idle, None, manifest)


def _evidence(region: Region, limit: int = 120) -> str:
    text = ' '.join(region.text.split())
    return text if len(text) <= limit else text[: limit - 1] + '\u2026'


def _iter_manifest_files(directory: str) -> Iterator[str]:
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return
    for name in names:
        if name.endswith('.toml'):
            yield os.path.join(directory, name)


def load_manifests(directory: str = '') -> dict[str, Manifest]:
    """Load every manifest, keyed by id and by alias.

    A manifest that fails to parse is logged and skipped, so one bad rule
    cannot take the whole sidebar down.
    """
    ans: dict[str, Manifest] = {}
    for path in _iter_manifest_files(directory or MANIFEST_DIR):
        try:
            with open(path, 'rb') as f:
                data = tomllib.load(f)
            manifest = parse_manifest(data, os.path.basename(path))
        except Exception as err:
            log_error(f'Ignoring invalid agent manifest {path}: {err}')
            continue
        for key in (manifest.id, *manifest.aliases):
            ans.setdefault(key, manifest)
    return ans


@lru_cache(maxsize=1)
def manifests() -> Mapping[str, Manifest]:
    return load_manifests()


def manifest_for(agent: str) -> Manifest | None:
    return manifests().get(agent)


def authority_for(agent: str) -> StateAuthority:
    """Who decides this agent's state.

    With no manifest there are no screen rules to consult, so a report is the
    only evidence available and has to be trusted. The state then falls back
    to unknown rather than idle, which is handled by the caller.
    """
    manifest = manifest_for(agent)
    return manifest.authority if manifest is not None else StateAuthority.full_lifecycle


def detect(agent: str, screen: Screen) -> Match:
    manifest = manifest_for(agent)
    if manifest is None:
        return Match(ManifestState.unknown, None, None)
    return evaluate(manifest, screen)


def all_agent_names() -> Iterable[str]:
    return manifests().keys()

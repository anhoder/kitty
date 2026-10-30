#!/usr/bin/env python
# License: GPLv3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

from kitty.agent_manifest import (
    MISSING,
    Screen,
    StateAuthority,
    authority_for,
    detect,
    load_manifests,
    manifest_for,
    resolve_region,
    translate_regex,
)
from kitty.agents import AgentSidebarRow, AgentState, AgentTracker, detect_agent, group_sidebar_rows, state_code, state_from_signals, state_icon

from .base import BaseTest


def screen(*lines: str, title: str = '', progress: str = '') -> Screen:
    return Screen(lines, title, progress)


class TestAgents(BaseTest):
    def test_detect_agent_from_foreground_command(self):
        self.ae(detect_agent([{'cmdline': ['/usr/local/bin/claude', '--resume', 'x']}]), 'claude')
        self.ae(detect_agent([{'cmdline': ['node', '/opt/opencode/bin/opencode']}]), 'opencode')
        self.ae(detect_agent([{'cmdline': ['omp', '--agent', 'opencode']}]), 'omp')
        # Registry values are manifest ids, not display names
        self.ae(detect_agent([{'cmdline': ['antigravity']}]), 'agy')
        self.ae(detect_agent([{'cmdline': ['qoder']}]), 'qodercli')
        self.assertIsNone(detect_agent([{'cmdline': ['/bin/zsh', '-l']}]))
        self.assertIsNone(detect_agent([]))

    # region slicing

    def test_bottom_non_empty_lines_skips_blank_padding(self):
        # An agent TUI pads the area below its status line with blank rows. A
        # raw physical-line tail sees only the padding.
        s = screen('user: go', '', '\u2733 Thinking\u2026 (12s \u00b7 esc to interrupt)', '', '', '', '')
        region = resolve_region('bottom_non_empty_lines(2)', s)
        self.ae(region.lines, ['user: go', '\u2733 Thinking\u2026 (12s \u00b7 esc to interrupt)'])

    def test_top_non_empty_lines(self):
        s = screen('', 'first', 'second', 'third')
        self.ae(resolve_region('top_non_empty_lines(2)', s).lines, ['first', 'second'])

    def test_bottom_lines_counts_physical_rows(self):
        # Unlike bottom_non_empty_lines, blank rows consume the budget
        s = screen('a', '', 'b', 'c')
        self.ae(resolve_region('bottom_lines(2)', s).lines, ['b', 'c'])
        self.ae(resolve_region('bottom_lines(3)', s).lines, ['', 'b', 'c'])

    def test_osc_regions(self):
        s = screen('body', title='\u280f | tmp', progress='4;1;-1')
        self.ae(resolve_region('osc_title', s).text, '\u280f | tmp')
        self.ae(resolve_region('osc_progress', s).text, '4;1;-1')
        # Absent OSC data is a missing region, not an empty one
        self.assertFalse(resolve_region('osc_progress', screen('body')).present)

    def test_after_last_horizontal_rule(self):
        s = screen('old', '\u2500\u2500\u2500\u2500', 'first block', '\u2500\u2500\u2500\u2500', 'live block')
        self.ae(resolve_region('after_last_horizontal_rule', s).lines, ['live block'])
        self.assertFalse(resolve_region('after_last_horizontal_rule', screen('no rule here')).present)

    def test_prompt_box_regions(self):
        s = screen(
            'transcript line',
            'status above box',
            '\u256d\u2500 header \u2500\u256e',
            '\u2502 \u276f typed text',
            '\u2570\u2500\u2500\u2500\u256f',
            'footer hint',
        )
        # Borders are stripped so a rule can anchor on the marker at column zero
        self.ae(resolve_region('prompt_box_body', s).lines, ['\u276f typed text'])
        self.ae(resolve_region('last_non_empty_above_prompt_box', s).text, 'status above box')
        self.assertFalse(resolve_region('prompt_box_body', screen('no box')).present)

    def test_prompt_marker_regions(self):
        s = screen('older output', '\u203a live prompt', 'queued below')
        self.ae(resolve_region('after_last_prompt_marker', s).lines, ['queued below'])
        self.ae(resolve_region('before_current_prompt_marker', s).lines, ['older output'])
        self.ae(
            resolve_region('whole_recent_without_current_prompt_marker', s).lines,
            ['older output', 'queued below'],
        )

    def test_unknown_region_is_missing(self):
        self.ae(resolve_region('no_such_region', screen('x')), MISSING)

    # gates

    def test_contains_is_conjunctive_and_regex_is_disjunctive(self):
        m = manifest_for('claude')
        rule = next(r for r in m.rules if r.id == 'live_blocked_form')
        # Footer alone is not enough; it co-occurs with working turns too.
        self.assertFalse(rule.gate.matches(resolve_region(rule.region, screen('esc to cancel'))))
        ok = resolve_region(rule.region, screen('\u2500\u2500\u2500\u2500', 'enter to confirm \u00b7 esc to cancel'))
        self.assertTrue(rule.gate.matches(ok))

    def test_contains_ignores_case(self):
        # The manifests depend on this. Claude's permission rule looks for
        # 'do you want to proceed?' while Claude Code draws it capitalised, so
        # a case-sensitive compare would never fire and a real approval prompt
        # would read as idle.
        prompt = screen(
            '\u2500' * 8,
            'Do you want to proceed?',
            '\u276f 1. Yes',
            '  2. No',
            'esc to cancel',
        )
        match = detect('claude', prompt)
        self.ae(match.state.value, 'blocked')
        self.ae(match.rule_id, 'generic_permission_prompt')

    def test_not_gate_blocks_match(self):
        m = manifest_for('codex')
        rule = next(r for r in m.rules if r.id == 'osc_title_idle')
        self.assertTrue(rule.gate.matches(resolve_region(rule.region, screen(title='tmp'))))
        # A spinner or an alert in the title is not idle
        self.assertFalse(rule.gate.matches(resolve_region(rule.region, screen(title='\u280b tmp'))))
        self.assertFalse(rule.gate.matches(resolve_region(rule.region, screen(title='Action Required'))))

    def test_rust_codepoint_escapes_are_translated(self):
        import re

        # Python has no \x{...} syntax, so the raw Rust pattern cannot compile
        self.assertRaises(re.error, re.compile, r'[\x{2800}-\x{28FF}]')
        # After translation it compiles and matches the intended code points
        braille = translate_regex(r'^[\x{2800}-\x{28FF}] ')
        self.assertTrue(re.search(braille, '\u2809 Thinking'))
        self.assertFalse(re.search(braille, 'x Idle'))
        # Codex's half-circle and braille title spinners
        self.assertTrue(re.search(translate_regex(r'[\x{25D0}-\x{25D3}]'), '\u25d1'))

    def test_rust_unicode_classes_and_u_escapes_are_translated(self):
        import re

        # \p{...} and \u{...} are Rust-only spellings. Plain \uXXXX is valid
        # Python already, so it is deliberately not in this list.
        for raw in (r'\p{Alphabetic}+', r'[\u{fe0e}\u{fe0f}]'):
            self.assertRaises(re.error, re.compile, raw)

        # Cursor's spinner rule needs all three at once
        spinner = re.compile(translate_regex(r'^\s*(\u2b21|\u2b22|[\u2800-\u28FF]+)\s+\p{Alphabetic}+\w*ing\b'))
        self.assertTrue(spinner.search('\u2b21 Thinking'))
        self.assertTrue(spinner.search('\u280f\u2819 Generating'))
        self.assertFalse(spinner.search('\u2b21 123ing'))

        # Hermes anchors on an emoji with an optional variation selector
        warn = re.compile(translate_regex(r'^\u26a0[\u{fe0e}\u{fe0f}]?(?:\s|$)'))
        self.assertTrue(warn.search('\u26a0 alert'))
        self.assertTrue(warn.search('\u26a0\ufe0f '))
        self.assertFalse(warn.search('x \u26a0'))

    def test_every_shipped_manifest_loads_completely(self):
        import os
        import tomllib

        from kitty.agent_manifest import MANIFEST_DIR, parse_manifest

        seen = 0
        for fn in sorted(os.listdir(MANIFEST_DIR)):
            if not fn.endswith('.toml'):
                continue
            with open(os.path.join(MANIFEST_DIR, fn), 'rb') as f:
                raw = tomllib.load(f)
            # A rule dropped for an unsupported region or an uncompilable
            # regex would silently weaken detection, so assert none are lost.
            m = parse_manifest(raw, fn)
            self.ae(len(m.rules), len(raw['rules']), f'{fn} lost rules')
            self.ae(m.id, fn[:-5])
            seen += 1
        self.assertGreater(seen, 20)

    # manifests

    def test_manifests_load_with_aliases(self):
        ms = load_manifests()
        for name in ('claude', 'codex', 'opencode'):
            self.assertIn(name, ms)
        self.ae(manifest_for('claude-code').id, 'claude')
        self.assertIsNone(manifest_for('nosuchagent'))

    def test_state_authority_follows_hook_coverage(self):
        # OpenCode's plugin reports every transition; Claude and Codex hooks
        # only report session identity.
        self.ae(authority_for('opencode'), StateAuthority.full_lifecycle)
        self.ae(authority_for('claude'), StateAuthority.identity_only)
        self.ae(authority_for('codex'), StateAuthority.identity_only)
        # omp has screen rules, so a report does not get to override them
        self.ae(authority_for('omp'), StateAuthority.identity_only)
        # An agent with no manifest has no screen rules at all, so a report is
        # the only evidence there is
        self.ae(authority_for('mastracode'), StateAuthority.full_lifecycle)

    def test_agent_without_rules_reports_unknown_not_idle(self):
        # mastracode is recognized by name but ships no rules. Saying idle
        # would present a guess as a fact.
        quiet = screen('some output with no markers')
        self.ae(state_from_signals('mastracode', [], quiet), AgentState.unknown)
        # a report is still honoured
        self.ae(state_from_signals('mastracode', [{'state': 'working'}], quiet), AgentState.working)

    def test_omp_title_and_prompt_header(self):
        # Titles verbatim from live omp panes. The marker after the pi glyph is
        # the signal; the pi glyph itself is present in both states, so a rule
        # anchored on the spinner alone never fires.
        working = screen(title='\u03c0 \u2819 \U0001f442 HERDR: Align kitty state monitoring with herdr')
        self.ae(detect('omp', working).state.value, 'working')
        self.ae(detect('omp', screen(title='\u03c0 \u283c \U0001f442 HERDR: Fix omp agent sidebar status')).state.value, 'working')
        idle = screen(title='\u03c0 > \U0001f310 I18N: Split i18n sync audit prompt')
        self.ae(detect('omp', idle).state.value, 'idle')
        # Title disabled: the prompt box header carries the same distinction,
        # and adds elapsed turn time.
        busy_box = screen('\u256d\u2500\u2500 \u28a7 2m > \u25d2 Opus 5 > \U0001f4c1 ~/Desktop/kitty', '\u2570\u2500')
        self.ae(detect('omp', busy_box).state.value, 'working')
        rest_box = screen('\u256d\u2500\u2500 \u03c0 > \u25d2 gpt-6.1-sol > \U0001f4c1 ~/x', '\u2570\u2500')
        self.ae(detect('omp', rest_box).state.value, 'idle')
        # The model glyph shows in both states and is not activity
        self.assertNotEqual(detect('omp', rest_box).state.value, 'working')

    # detection

    def test_codex_title_spinner_cycle(self):
        # Matches the trace from `herdr agent explain` on a live codex pane.
        m = detect('codex', screen(title='tmp'))
        self.ae((m.state.value, m.rule_id), ('idle', 'osc_title_idle'))
        m = detect('codex', screen(title='\u280f | tmp'))
        self.ae((m.state.value, m.rule_id), ('working', 'osc_title_working'))
        m = detect('codex', screen(title='Action Required'))
        self.ae((m.state.value, m.rule_id), ('blocked', 'osc_title_blocked'))

    def test_highest_priority_rule_wins(self):
        # Both the blocked title rule (1100) and the idle title rule (100)
        # could describe this title; the blocker must win.
        m = detect('codex', screen(title='Action Required'))
        self.ae(m.rule.priority, 1100)

    def test_skip_state_update_holds_prior_state(self):
        transcript = screen('showing detailed transcript', '\u2191\u2193 scroll', '? for shortcuts')
        m = detect('claude', transcript)
        self.assertTrue(m.skipped)
        self.ae(state_from_signals('claude', [], transcript, AgentState.working), AgentState.working)
        self.ae(state_from_signals('claude', [], transcript, AgentState.blocked), AgentState.blocked)

    def test_no_rule_match_falls_back_to_idle(self):
        # Screen churn is not evidence of work.
        quiet = screen('some neutral transcript text')
        for agent in ('claude', 'codex', 'opencode'):
            self.ae(state_from_signals(agent, [], quiet), AgentState.idle)

    def test_unknown_agent_is_unknown(self):
        self.ae(state_from_signals(None, [{'state': 'blocked'}]), AgentState.unknown)

    # arbitration

    def test_full_lifecycle_report_wins(self):
        working = screen(title='')
        self.ae(state_from_signals('opencode', [{'state': 'blocked'}], working), AgentState.blocked)
        self.ae(state_from_signals('opencode', [{'state': 'done'}], working), AgentState.done)

    def test_identity_only_report_is_discarded(self):
        # A cancelled Claude turn leaves a stale working report while the
        # screen shows the idle prompt box. The screen must win.
        idle = screen('\u256d\u2500\u2500\u256e', '\u2502 \u276f ', '\u2570\u2500\u2500\u256f')
        self.ae(state_from_signals('claude', [{'state': 'working'}], idle), AgentState.idle)
        # And a live spinner must not be overridden by a stale done record.
        busy = screen('\u2733 Thinking\u2026 (3s \u00b7 esc to interrupt)')
        self.ae(state_from_signals('claude', [{'state': 'done'}], busy), AgentState.working)

    def test_state_icons_are_stable(self):
        self.ae([state_icon(s) for s in AgentState], ['\xb7', '\u27f3', '\u25cf', '\u2713', '?'])

    def test_state_codes_are_stable(self):
        self.ae([state_code(s) for s in AgentState], [1, 2, 3, 4, 0])

    def test_sidebar_grouping_strategies(self):
        rows = (
            AgentSidebarRow(1, 'Today', 'omp', 'omp', 'tmp · idle', AgentState.idle, False),
            AgentSidebarRow(2, 'Today', 'claude', 'claude', 'tmp · working', AgentState.working, False),
            AgentSidebarRow(3, 'Yesterday', 'omp', 'omp', 'tmp · done', AgentState.done, False),
        )
        by_time = group_sidebar_rows(rows, 'time')
        self.ae([r.window_id for r in by_time], [1, 2, 3])
        by_agent = group_sidebar_rows(rows, 'agent')
        self.ae([r.agent for r in by_agent], ['claude', 'omp', 'omp'])
        self.ae([r.group for r in by_agent], ['claude', 'omp', 'omp'])

    def test_sidebar_grouping_tab_and_path(self):
        rows = (
            AgentSidebarRow(1, 'Project A', 'omp', 'omp', 'a', AgentState.idle, False),
            AgentSidebarRow(2, 'Project B', 'claude', 'claude', 'b', AgentState.working, False),
            AgentSidebarRow(3, '/tmp/project', 'omp', 'omp', 'c', AgentState.done, False),
        )
        by_path = group_sidebar_rows(rows, 'path')
        self.ae([r.group for r in by_path], ['/tmp/project', 'Project A', 'Project B'])

    def test_sidebar_same_title_tabs(self):
        from types import SimpleNamespace
        from unittest.mock import patch

        from kitty.agents import AgentSnapshot
        from kitty.boss import Boss

        class Tab(list):
            effective_title = 'Project'

        class TabManager(list):
            agent_sidebar_rows = ()

            def set_agent_sidebar_rows(self, rows):
                self.agent_sidebar_rows = tuple(rows)

        windows = [SimpleNamespace(id=i) for i in range(1, 12)]
        tabs = [Tab([window]) for window in windows[:10]]
        tabs[0].append(windows[10])
        scope = (TabManager(tabs[:1]), TabManager(tabs[1:]))
        tracker = AgentTracker()
        tracker.snapshots = {
            w.id: AgentSnapshot(w.id, 'omp', AgentState.idle, 'omp', '/tmp') for w in windows
        }
        boss = SimpleNamespace(active_window=windows[1], agent_tracker=tracker)
        with patch('kitty.boss.get_options', return_value=SimpleNamespace(agents_sidebar_grouping='tab')):
            Boss._refresh_agent_sidebar_scope(boss, scope)
            rows = scope[0].agent_sidebar_rows
            self.ae([r.window_id for r in rows], [1, 11, *range(2, 11)])
            self.ae(len({r.group for r in rows}), 10)
            self.ae(rows[0].group, rows[1].group)
            self.assertNotEqual(rows[0].group, rows[2].group)
            self.ae(scope[1].agent_sidebar_rows, rows)
            self.ae([r.window_id for r in rows if r.is_active], [2])

            # Reordering and closing tabs must update numbering, not membership.
            scope[1].reverse()
            scope[0].clear()
            Boss._refresh_agent_sidebar_scope(boss, scope)
            rows = scope[1].agent_sidebar_rows
            self.ae([r.window_id for r in rows], list(range(10, 1, -1)))
            self.ae(len({r.group for r in rows}), 9)


class FakeWindow:
    id = 7
    title = 'Claude'

    def __init__(self, *lines: str, title: str = '', status=(), focused: bool = False):
        self.lines = lines
        self.osc_title = title
        self.status = list(status)
        self.is_focused = focused
        self.child = type('Child', (), {'cwd': '/tmp', 'foreground_processes': [{'cmdline': ['claude']}]})()
        self.program_status = type('S', (), {'as_list': lambda self_: self.status})()
        self.cwd_of_child = '/tmp'

    def agent_detection_snapshot(self):
        return Screen(self.lines, self.osc_title, '')


class TestAgentTracker(BaseTest):
    def test_tracker_caches_and_coalesces_windows(self):
        tracker = AgentTracker()
        self.assertTrue(tracker.refresh_window(FakeWindow('idle text')))
        self.assertFalse(tracker.refresh_window(FakeWindow('idle text')))
        tracker.mark_dirty(7)
        tracker.mark_dirty(7)
        self.ae(tracker.drain_dirty(), (7,))

    def test_discard_clears_all_window_state(self):
        tracker = AgentTracker()
        tracker.refresh_window(FakeWindow('idle text'))
        tracker.mark_dirty(7)
        tracker.discard(7)
        self.ae(tracker.drain_dirty(), ())
        self.assertIsNone(tracker.snapshot_for(7))

    def test_plain_idle_after_working_is_held_briefly(self):
        # Focused, so the finish does not turn into done and this isolates the
        # anti-flicker hold.
        tracker = AgentTracker()
        busy = FakeWindow('\u2733 Thinking\u2026 (3s \u00b7 esc to interrupt)', focused=True)
        tracker.refresh_window(busy, now=100.0)
        self.ae(tracker.snapshot_for(7).state, AgentState.working)
        # Mid-repaint: the working marker is gone but no idle marker yet.
        quiet = FakeWindow('neutral text', focused=True)
        tracker.refresh_window(quiet, now=100.1)
        self.ae(tracker.snapshot_for(7).state, AgentState.working)
        tracker.refresh_window(quiet, now=100.4)
        self.ae(tracker.snapshot_for(7).state, AgentState.idle)

    def test_visible_idle_evidence_applies_immediately(self):
        tracker = AgentTracker()
        tracker.refresh_window(FakeWindow('\u2733 Thinking\u2026 (3s \u00b7 esc to interrupt)', focused=True), now=100.0)
        self.ae(tracker.snapshot_for(7).state, AgentState.working)
        box = FakeWindow('\u256d\u2500\u2500\u256e', '\u2502 \u276f ', '\u2570\u2500\u2500\u256f', focused=True)
        tracker.refresh_window(box, now=100.05)
        self.ae(tracker.snapshot_for(7).state, AgentState.idle)

    def test_finished_turn_becomes_done_while_unfocused(self):
        tracker = AgentTracker()
        busy = FakeWindow('\u2733 Thinking\u2026 (3s \u00b7 esc to interrupt)')
        tracker.refresh_window(busy, now=100.0)
        self.ae(tracker.snapshot_for(7).state, AgentState.working)
        # Turn ends with the prompt box back. The user is looking elsewhere, so
        # the completion must be surfaced rather than quietly becoming idle.
        box = FakeWindow('\u256d\u2500\u2500\u256e', '\u2502 \u276f ', '\u2570\u2500\u2500\u256f')
        tracker.refresh_window(box, now=100.1)
        self.ae(tracker.snapshot_for(7).state, AgentState.done)
        # It stays done across refreshes until seen.
        tracker.refresh_window(box, now=101.0)
        self.ae(tracker.snapshot_for(7).state, AgentState.done)

    def test_done_clears_once_the_window_is_focused(self):
        tracker = AgentTracker()
        tracker.refresh_window(FakeWindow('\u2733 Thinking\u2026 (3s \u00b7 esc to interrupt)'), now=100.0)
        box = FakeWindow('\u256d\u2500\u2500\u256e', '\u2502 \u276f ', '\u2570\u2500\u2500\u256f')
        tracker.refresh_window(box, now=100.1)
        self.ae(tracker.snapshot_for(7).state, AgentState.done)
        seen = FakeWindow('\u256d\u2500\u2500\u256e', '\u2502 \u276f ', '\u2570\u2500\u2500\u256f', focused=True)
        tracker.refresh_window(seen, now=100.2)
        self.ae(tracker.snapshot_for(7).state, AgentState.idle)
        self.assertNotIn(7, tracker.unseen_done)

    def test_finishing_while_focused_never_shows_done(self):
        # The user is watching the turn end, so there is nothing to catch up on.
        tracker = AgentTracker()
        tracker.refresh_window(FakeWindow('\u2733 Thinking\u2026 (3s \u00b7 esc to interrupt)', focused=True), now=100.0)
        box = FakeWindow('\u256d\u2500\u2500\u256e', '\u2502 \u276f ', '\u2570\u2500\u2500\u256f', focused=True)
        tracker.refresh_window(box, now=100.1)
        self.ae(tracker.snapshot_for(7).state, AgentState.idle)

    def test_new_turn_supersedes_an_unseen_completion(self):
        tracker = AgentTracker()
        busy = FakeWindow('\u2733 Thinking\u2026 (3s \u00b7 esc to interrupt)')
        tracker.refresh_window(busy, now=100.0)
        box = FakeWindow('\u256d\u2500\u2500\u256e', '\u2502 \u276f ', '\u2570\u2500\u2500\u256f')
        tracker.refresh_window(box, now=100.1)
        self.ae(tracker.snapshot_for(7).state, AgentState.done)
        # Working again: the completion is no longer the latest thing.
        tracker.refresh_window(busy, now=100.2)
        self.ae(tracker.snapshot_for(7).state, AgentState.working)
        self.assertNotIn(7, tracker.unseen_done)

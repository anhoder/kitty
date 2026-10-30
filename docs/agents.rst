AI agents sidebar
==================

kitty can monitor recognized AI coding agents running in its terminal windows and
show them in a native macOS vertical surface on the left side of the kitty
window. It is not a nested TUI and does not use kitty's existing tab-bar
renderer.

Enable the sidebar and map the toggle action in :file:`kitty.conf`::

    map kitty_mod+a toggle_agents_sidebar

Click an agent row to focus its window. Press the mapped shortcut again to
restore the normal tab list.

The macOS surface uses a translucent sidebar material, grouped time sections,
two-line agent rows, colored state indicators, and active-row highlighting.
A working agent shows a turning arc in place of the state dot; the animation
only runs while something is actually working. Drag the sidebar's right edge
to change its width. The sidebar always spans the full window height, and the
``AGENTS`` header remains at the top when the window is resized.

Set :opt:`agents_sidebar_auto_show` to :code:`yes` to open the sidebar
automatically when the first recognized foreground agent is detected. The
automatic detector polls only while the sidebar is closed and stops once it
opens; the default is :code:`no`.

The sidebar visibility is global for the kitty process. Toggling it in any tab
opens or closes it in every existing and newly created tab; the Agent rows remain
scoped to the current native tab group or OS window.


Agents are recognized by their foreground process. kitty ships detection rules
for Claude Code, Codex, OpenCode, Gemini, GitHub Copilot, Cursor Agent, Grok,
Qwen, Kimi, Kiro, Kilo, Cline, Droid, Devin, Amp, Muse, Maki, Letta, Hermes,
Antigravity, Qoder and pi. A process is shown only while it is the foreground
process of a kitty window; unsupported programs remain ordinary terminal
windows and are not shown.

How a state is decided
-------------------------

The foreground process answers *which* agent is in the window. It does not
answer *what the agent is doing*. That comes from one of two sources:

* For agents whose integration reports every lifecycle transition, their own
  OSC 7501 program-status records.
* For every other agent, the live contents of the window.

The distinction matters. An integration that only reports session identity has
no handler for cancelled turns and interrupts, so its last report goes stale
and would otherwise pin the window to a state its own screen contradicts.

Screen detection is rule-based. Each agent has a table of rules in
:file:`kitty/agent_manifests/`, and each rule matches inside one named region
of the window: the title, the OSC 9;4 progress payload, the bottom few
non-empty lines, the prompt box interior, the text below the last horizontal
rule, and so on. Every rule is evaluated and the highest-priority match wins.

Two properties follow from this design and are worth knowing:

* ``working`` requires a visible marker, such as a spinner, an interrupt hint,
  a progress bar or a live timer. Output scrolling past is not treated as work,
  because an agent that has finished its turn can still have background tasks
  writing to the window.
* Screens that replace the live interface, such as a transcript viewer or a
  model picker, hold the previous state rather than reporting a new one. They
  say nothing about what the agent is doing, and guessing from them would flip
  a working agent to idle while the user is only reading back.

The displayed states are ``working``, ``blocked``, ``done``, ``idle`` and
``unknown``. ``done`` only ever comes from a program-status record, since
completion is not something the screen can show reliably. ``unknown`` means the
process is a recognized agent but kitty ships no rules for it, so its activity
genuinely cannot be read; it is reported rather than guessing ``idle``.

When a screen-detected agent finishes while its window is not focused, kitty
keeps ``done`` instead of immediately returning to ``idle``. Viewing the
window clears it to ``idle``. Kitty also emits a desktop notification for the
transition; clicking that notification focuses the corresponding agent
window.

The sidebar is scoped to the current kitty tab group. With macOS native tabs,
all tabs in the native tab group share one Agents list and each tab displays the
same sidebar. Without native tabs, it covers all kitty tabs in the current OS
window. It does not keep agent processes alive after kitty exits.
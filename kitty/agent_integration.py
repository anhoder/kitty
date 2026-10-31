#!/usr/bin/env python
# License: GPLv3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

# Install the hooks that let AI coding agents tell kitty which conversation they are in, so that kitty can resume that
# conversation when it restores a saved session, see resume_agents_on_restore.
#
# An agent reports its session id by setting a kitty user var over OSC 1337. The hook that does it runs as a subprocess of the
# agent, and Claude Code runs its hooks without a controlling terminal, so the hook cannot use /dev/tty. It writes to
# KITTY_WINDOW_TTY instead, the device of the kitty window the agent runs in, which kitty puts in the environment of every child.
# Writing to it needs no remote control, no socket and no cooperation from the agent beyond running the hook.

import json
import os
import shutil
from collections.abc import Callable, Sequence
from typing import Any, NamedTuple

from .agents import AGENT_ID_VAR, AGENT_SESSION_VAR, AGENT_SOURCE_VAR
from .constants import config_dir

HOOK_DIR_NAME = 'agent-integration'
# Written by the hook, read by kitty/window.py's OSC 1337 handler
HOOK_SCRIPT = r'''#!/bin/sh
# Installed by kitty, see kitty/agent_integration.py. Tells kitty which agent conversation this window is in, so that kitty can
# resume it after a restart. Does nothing outside kitty and never fails in a way the agent can see.
set -u
tty_path="${KITTY_WINDOW_TTY:-}"
[ -n "$tty_path" ] || exit 0
[ -w "$tty_path" ] || exit 0
session_id="${%(id_env)s:-}"
if [ -z "$session_id" ]; then
    # The id is on stdin as JSON when the agent does not export it
    session_id=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
fi
[ -n "$session_id" ] || exit 0
encoded=$(printf %%s "$session_id" | base64 | tr -d '\n')
printf '\033]1337;SetUserVar=%(session_var)s=%%s\007' "$encoded" > "$tty_path" 2>/dev/null || exit 0
printf '\033]1337;SetUserVar=%(agent_var)s=%%s\007' "$(printf %%s '%(agent)s' | base64 | tr -d '\n')" > "$tty_path" 2>/dev/null || exit 0
printf '\033]1337;SetUserVar=%(source_var)s=%%s\007' "$(printf %%s 'kitty:%(agent)s' | base64 | tr -d '\n')" > "$tty_path" 2>/dev/null || exit 0
exit 0
'''


class Agent(NamedTuple):
    # The manifest id, which is also what a saved session records
    id: str
    name: str
    # The environment variable the agent sets to the session id in hook subprocesses, empty if it sets none
    id_env: str
    # Where the agent keeps the configuration its hooks are registered in
    config_path: Callable[[], str]
    # Official integration mechanism. Plugin-only agents cannot use kitty's generic shell hook safely.
    integration_kind: str = 'hook'
    hook_event: str = 'SessionStart'


def hook_dir() -> str:
    return os.path.join(config_dir, HOOK_DIR_NAME)


def hook_path(agent: str) -> str:
    return os.path.join(hook_dir(), f'{agent}-session.sh')


def write_hook(agent: Agent) -> str:
    path = hook_path(agent.id)
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    script = HOOK_SCRIPT % {
        'agent': agent.id,
        'id_env': agent.id_env or 'KITTY_UNSET_SESSION_ID',
        'session_var': AGENT_SESSION_VAR,
        'agent_var': AGENT_ID_VAR,
        'source_var': AGENT_SOURCE_VAR,
    }
    with open(path, 'w') as f:
        f.write(script)
    os.chmod(path, 0o700)
    return path


def read_json(path: str) -> dict[str, Any]:
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        return {}
    except Exception as err:
        raise SystemExit(f'Cannot read {path}: {err}') from err
    if not isinstance(data, dict):
        raise SystemExit(f'Cannot read {path}: expected a JSON object')
    return data


def write_json(path: str, data: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        shutil.copy2(path, path + '.kitty-backup')
    tmp = path + '.kitty-tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    os.replace(tmp, path)


def is_kitty_hook(entry: Any) -> bool:
    return isinstance(entry, dict) and 'kitty' in str(entry.get('command', ''))



def claude_settings_path() -> str:
    return os.path.join(os.path.expanduser(os.environ.get('CLAUDE_CONFIG_DIR') or '~/.claude'), 'settings.json')


def codex_hooks_path() -> str:
    return os.path.join(os.path.expanduser(os.environ.get('CODEX_HOME') or '~/.codex'), 'hooks.json')


def home_config_path(env_name: str, default: str, filename: str) -> Callable[[], str]:
    def resolve() -> str:
        return os.path.join(os.path.expanduser(os.environ.get(env_name) or default), filename)

    return resolve


def unsupported_config_path() -> str:
    return ''


def hook_entry(script: str) -> dict[str, Any]:
    return {'type': 'command', 'command': script, 'timeout': 5}


def register_hook(path: str, script: str) -> None:
    """Add a SessionStart command hook, keeping every other hook in the file.

    Claude Code's settings.json and Codex's hooks.json use the same shape: a
    top level hooks object maps an event to a list of matcher groups, each
    holding a list of handlers.
    """
    data = read_json(path)
    hooks = data.setdefault('hooks', {})
    if not isinstance(hooks, dict):
        raise SystemExit(f'Cannot use {path}: hooks is not an object')
    groups = hooks.setdefault('SessionStart', [])
    if not isinstance(groups, list):
        raise SystemExit(f'Cannot use {path}: hooks.SessionStart is not a list')
    for group in groups:
        entries = group.get('hooks') if isinstance(group, dict) else None
        if isinstance(entries, list):
            for i, entry in enumerate(entries):
                if is_kitty_hook(entry):  # already installed, update it in place
                    entries[i] = hook_entry(script)
                    write_json(path, data)
                    return
    groups.append({'hooks': [hook_entry(script)]})
    write_json(path, data)


def unregister_hook(path: str) -> None:
    data = read_json(path)
    hooks = data.get('hooks')
    if not isinstance(hooks, dict) or not isinstance(hooks.get('SessionStart'), list):
        return
    kept = []
    for group in hooks['SessionStart']:
        if isinstance(group, dict) and isinstance(group.get('hooks'), list):
            group['hooks'] = [e for e in group['hooks'] if not is_kitty_hook(e)]
            if not group['hooks']:
                continue
        kept.append(group)
    if kept:
        hooks['SessionStart'] = kept
    else:
        hooks.pop('SessionStart', None)
    write_json(path, data)


def hook_is_installed(path: str) -> bool:
    hooks = read_json(path).get('hooks') if os.path.exists(path) else None
    if not isinstance(hooks, dict):
        return False
    for group in hooks.get('SessionStart') or ():
        if isinstance(group, dict) and any(is_kitty_hook(e) for e in group.get('hooks') or ()):
            return True
    return False


AGENTS: tuple[Agent, ...] = (
    Agent('claude', 'Claude Code', 'CLAUDE_CODE_SESSION_ID', claude_settings_path, 'hook'),
    Agent('codex', 'Codex', '', codex_hooks_path, 'hook'),
    Agent('copilot', 'GitHub Copilot CLI', '', home_config_path('COPILOT_HOME', '~/.copilot', 'settings.json'), 'adapter-required'),
    Agent('devin', 'Devin CLI', '', home_config_path('XDG_CONFIG_HOME', '~/.config', 'devin/config.json'), 'adapter-required'),
    Agent('droid', 'Droid', '', home_config_path('FACTORY_HOME', '~/.factory', 'settings.json'), 'adapter-required'),
    Agent('kimi', 'Kimi Code CLI', '', home_config_path('KIMI_CODE_HOME', '~/.kimi-code', 'config.toml'), 'adapter-required'),
    Agent('qodercli', 'Qoder CLI', '', home_config_path('QODER_CONFIG_DIR', '~/.qoder', 'settings.json'), 'adapter-required'),
    Agent('qwen', 'Qwen Code', '', home_config_path('QWEN_HOME', '~/.qwen', 'settings.json'), 'adapter-required'),
    Agent('letta', 'Letta Code', '', home_config_path('LETTA_HOME', '~/.letta', 'settings.json'), 'adapter-required'),
    Agent('cursor', 'Cursor Agent CLI', '', home_config_path('CURSOR_CONFIG_DIR', '~/.cursor', 'hooks.json'), 'adapter-required'),
    Agent('grok', 'Grok CLI', '', home_config_path('GROK_HOME', '~/.grok', 'hooks/herdr.json'), 'adapter-required'),
    Agent('agy', 'Antigravity CLI', '', home_config_path('ANTIGRAVITY_CLI_CONFIG_DIR', '~/.gemini/config', 'hooks.json'), 'adapter-required'),
    Agent('mastracode', 'MastraCode', '', home_config_path('MASTRACODE_HOME', '~/.mastracode', 'hooks.json'), 'adapter-required'),
    Agent('pi', 'Pi', '', home_config_path('PI_CODING_AGENT_DIR', '~/.pi/agent', 'extensions/herdr-agent-state.ts'), 'native'),
    Agent('omp', 'OMP', '', home_config_path('PI_CODING_AGENT_DIR', '~/.omp/agent', 'extensions/herdr-omp-agent-state.ts'), 'native'),
    Agent('opencode', 'OpenCode', '', home_config_path('XDG_CONFIG_HOME', '~/.config', 'opencode/plugins/herdr-agent-state.js'), 'plugin-required'),
    Agent('kilo', 'Kilo Code CLI', '', home_config_path('XDG_CONFIG_HOME', '~/.config', 'kilo/plugin/herdr-agent-state.js'), 'plugin-required'),
    Agent('hermes', 'Hermes Agent', '', home_config_path('HERMES_HOME', '~/.hermes', 'plugins/herdr-agent-state/plugin.yaml'), 'plugin-required'),
)


def agent_by_id(agent_id: str) -> Agent:
    for agent in AGENTS:
        if agent.id == agent_id:
            return agent
    known = ', '.join(a.id for a in AGENTS)
    raise SystemExit(f'Unknown agent: {agent_id}. Known agents: {known}')


def install(agent_id: str) -> str:
    agent = agent_by_id(agent_id)
    if agent.integration_kind != 'hook':
        raise SystemExit(
            f'{agent.name} requires a native kitty adapter for its official integration ({agent.integration_kind}); '
            f'kitty will not write a generic hook into {agent.config_path()}.'
        )
    path = agent.config_path()
    if not path or not os.path.isdir(os.path.dirname(path)):
        raise SystemExit(f'{agent.name} is not configured on this computer: {os.path.dirname(path) or "no config path"} does not exist')
    register_hook(path, write_hook(agent))
    return f'Installed the kitty session hook for {agent.name} in {path}'


def uninstall(agent_id: str) -> str:
    agent = agent_by_id(agent_id)
    if agent.integration_kind != 'hook':
        return f'{agent.name} requires its native integration adapter; kitty has no generic hook to uninstall'
    path = agent.config_path()
    unregister_hook(path)
    script = hook_path(agent.id)
    if os.path.exists(script):
        os.remove(script)
    return f'Removed the kitty session hook for {agent.name} from {path}'


def status() -> list[str]:
    ans = []
    for agent in AGENTS:
        if agent.integration_kind == 'native':
            ans.append(f'{agent.id:8} native           {agent.config_path()}')
            continue
        if agent.integration_kind == 'plugin-required':
            ans.append(f'{agent.id:8} plugin-required {agent.config_path()}')
            continue
        path = agent.config_path()
        state = 'installed' if hook_is_installed(path) else 'not installed'
        ans.append(f'{agent.id:8} {state:14} {path}')
    return ans


def main(args: Sequence[str]) -> None:
    if len(args) < 2 or args[1] in ('-h', '--help'):
        names = ', '.join(a.id for a in AGENTS)
        raise SystemExit(f'Usage: kitty +agent-integration [install|uninstall] <agent>|status\n\nKnown agents: {names}')
    cmd = args[1]
    if cmd == 'status':
        print('\n'.join(status()))
        return
    if cmd not in ('install', 'uninstall') or len(args) < 3:
        raise SystemExit('Usage: kitty +agent-integration [install|uninstall] <agent>|status')
    print(install(args[2]) if cmd == 'install' else uninstall(args[2]))
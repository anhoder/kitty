#!/usr/bin/env python
# License: GPL v3 Copyright: 2026, Kovid Goyal <kovid at kovidgoyal.net>

import os
import pwd
import tempfile
import unittest
from unittest.mock import patch

from kitty import child as child_mod
from kitty.child import _macos_login_shell_command


class TestChild(unittest.TestCase):
    def test_default_macos_shell_fork_skips_kitten(self):
        opts = type('Options', (), {'forward_stdio': False, 'shell_integration': {'enabled'}})()
        seen = {}

        def fake_spawn(exe, cwd, argv, env, *rest):
            seen['exe'] = exe
            seen['argv'] = tuple(argv)
            return 12345

        child = child_mod.Child([child_mod.shell_path], os.getcwd())
        child.get_final_env = lambda: ({}, False)
        with patch.object(child_mod.fast_data_types, 'get_options', return_value=opts), patch.object(child_mod.fast_data_types, 'spawn', side_effect=fake_spawn):
            child.fork()

        if child.child_fd is not None:
            os.close(child.child_fd)
            child.child_fd = None
        if child.terminal_ready_fd > -1:
            os.close(child.terminal_ready_fd)
            child.terminal_ready_fd = -1

        self.assertEqual(seen['exe'], '/usr/bin/login')
        self.assertEqual(seen['argv'][:4], ('/usr/bin/login', '-flp', pwd.getpwuid(os.geteuid()).pw_name, '/bin/bash'))
        self.assertNotIn('kitten', seen['argv'])
        self.assertTrue(seen['argv'][-1].startswith('exec -l '))

    def test_macos_login_shell_command_preserves_cwd_and_quotes(self):
        with tempfile.TemporaryDirectory() as home:
            argv, cwd = _macos_login_shell_command(
                ['/opt/homebrew/bin/fish', '--private', 'directory with spaces'],
                '/Users/test/project',
                'testuser',
                home,
            )

        self.assertEqual(cwd, '/Users/test/project')
        self.assertEqual(
            argv,
            [
                '/usr/bin/login',
                '-flp',
                'testuser',
                '/bin/bash',
                '--noprofile',
                '--norc',
                '-c',
                "exec -l /opt/homebrew/bin/fish --private 'directory with spaces'",
            ],
        )

    def test_macos_login_shell_command_honors_hushlogin(self):
        with tempfile.TemporaryDirectory() as home:
            with open(os.path.join(home, '.hushlogin'), 'w'):
                pass
            argv, _ = _macos_login_shell_command(['/bin/zsh'], '/tmp', 'testuser', home)

        self.assertEqual(argv[:2], ['/usr/bin/login', '-q'])
        self.assertEqual(argv[2:5], ['-flp', 'testuser', '/bin/bash'])

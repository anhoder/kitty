#!/usr/bin/env python
# License: GPL v3 Copyright: 2016, Kovid Goyal <kovid at kovidgoyal.net>

import fcntl
import math
import os
import re
import string
import sys
from collections.abc import Callable, Generator, Iterable, Iterator, Mapping, Sequence
from contextlib import contextmanager, suppress
from functools import lru_cache
from re import Match, Pattern
from typing import (
    TYPE_CHECKING,
    Any,
    BinaryIO,
    NamedTuple,
    Optional,
    cast,
)

from .constants import (
    clear_handled_signals,
    config_dir,
    is_macos,
    is_wayland,
    kitten_exe,
    runtime_dir,
    shell_path,
    ssh_control_master_template,
)
from .fast_data_types import WINDOW_FULLSCREEN, WINDOW_HIDDEN, WINDOW_MAXIMIZED, WINDOW_MINIMIZED, WINDOW_NORMAL, Color, Shlex, get_options, monotonic, open_tty
from .fast_data_types import timed_debug_print as _timed_debug_print
from .types import run_once
from .typing_compat import AddressFamily, PopenType, StartupCtx

if TYPE_CHECKING:
    import tarfile

    from .fast_data_types import OSWindowSize
    from .options.types import Options
else:
    Options = object


class Flag:

    def __init__(self, initial_val: bool = True) -> None:
        self.val = initial_val

    def __enter__(self) -> None:
        self.val ^= True

    def __exit__(self, *a: object) -> None:
        self.val ^= True

    def __bool__(self) -> bool:
        return self.val


disallow_expand_vars = Flag(False)


def expandvars(val: str, env: Mapping[str, str] = {}, fallback_to_os_env: bool = True) -> str:
    '''
    Expand $VAR and ${VAR} Use $$ for a literal $
    '''

    def sub(m: 'Match[str]') -> str:
        key = m.group(1) or m.group(2)
        result = env.get(key)
        if result is None and fallback_to_os_env:
            result = os.environ.get(key)
        if result is None:
            result = m.group()
        return result

    if disallow_expand_vars or '$' not in val:
        return val

    return re.sub(r'\$(?:(\w+)|\{([^}]+)\})', sub, val.replace('$$', '\0')).replace('\0', '$')


@lru_cache(maxsize=2)
def sgr_sanitizer_pat(for_splitting: bool = False) -> 're.Pattern[str]':
    pat = '\033\\[.*?m'
    if for_splitting:
        return re.compile(f'({pat})')
    return re.compile(pat)


@run_once
def kitty_ansi_sanitizer_pat() -> 're.Pattern[str]':
    # removes ANSI sequences generated by kitty's ANSI output routines. Not
    # suitable for stripping general ANSI sequences
    return re.compile(r'\x1b(?:\[[0-9;:]*?m|\].*?\x1b\\)')


def platform_window_id(os_window_id: int) -> int | None:
    if is_macos:
        from .fast_data_types import cocoa_window_id
        with suppress(Exception):
            return cocoa_window_id(os_window_id)
    if not is_wayland():
        from .fast_data_types import x11_window_id
        with suppress(Exception):
            return x11_window_id(os_window_id)
    return None


def safe_print(*a: Any, **k: Any) -> None:
    with suppress(Exception):
        print(*a, **k)


def log_error(*a: Any, **k: str) -> None:
    from .fast_data_types import log_error_string
    output = getattr(log_error, 'redirect', log_error_string)
    with suppress(Exception):
        msg = k.get('sep', ' ').join(map(str, a)) + k.get('end', '')
        output(msg)


@contextmanager
def suppress_error_logging() -> Iterator[None]:
    before = getattr(log_error, 'redirect', suppress_error_logging)
    setattr(log_error, 'redirect', lambda *a: None)
    try:
        yield
    finally:
        if before is suppress_error_logging:
            delattr(log_error, 'redirect')
        else:
            setattr(log_error, 'redirect', before)


def ceil_int(x: float) -> int:
    return int(math.ceil(x))


def sanitize_title(x: str) -> str:
    return re.sub(r'\s+', ' ', re.sub(r'[\0-\x19\x80-\x9f]', '', x))


def color_as_int(val: Color) -> int:
    return int(val) & 0xffffff


def color_from_int(val: int) -> Color:
    return Color((val >> 16) & 0xFF, (val >> 8) & 0xFF, val & 0xFF)


class ScreenSize(NamedTuple):
    rows: int
    cols: int
    width: int
    height: int
    cell_width: int
    cell_height: int


def read_screen_size(fd: int = -1) -> ScreenSize:
    import array
    import fcntl
    import termios
    buf = array.array('H', [0, 0, 0, 0])
    if fd < 0:
        fd = sys.stdout.fileno()
    fcntl.ioctl(fd, termios.TIOCGWINSZ, cast(bytearray, buf))
    rows, cols, width, height = tuple(buf)
    cell_width, cell_height = width // (cols or 1), height // (rows or 1)
    return ScreenSize(rows, cols, width, height, cell_width, cell_height)


class ScreenSizeGetter:
    changed = True
    Size = ScreenSize
    ans: ScreenSize | None = None

    def __init__(self, fd: int | None):
        if fd is None:
            fd = sys.stdout.fileno()
        self.fd = fd

    def __call__(self) -> ScreenSize:
        if self.changed:
            self.ans = read_screen_size(self.fd)
            self.changed = False
        return cast(ScreenSize, self.ans)


@lru_cache(maxsize=64, typed=True)
def screen_size_function(fd: int | None = None) -> ScreenSizeGetter:
    return ScreenSizeGetter(fd)


def fit_image(width: int, height: int, pwidth: int, pheight: int) -> tuple[int, int]:
    from math import floor
    if height > pheight:
        corrf = pheight / float(height)
        width, height = floor(corrf * width), pheight
    if width > pwidth:
        corrf = pwidth / float(width)
        width, height = pwidth, floor(corrf * height)
    if height > pheight:
        corrf = pheight / float(height)
        width, height = floor(corrf * width), pheight

    return int(width), int(height)


def base64_encode(
    integer: int,
    chars: str = string.ascii_uppercase + string.ascii_lowercase + string.digits +
    '+/'
) -> str:
    ans = ''
    while True:
        integer, remainder = divmod(integer, 64)
        ans = chars[remainder] + ans
        if integer == 0:
            break
    return ans


def command_for_open(program: str | list[str] = 'default') -> list[str]:
    if isinstance(program, str):
        from .conf.utils import to_cmdline
        program = to_cmdline(program)
    if program == ['default']:
        cmd = ['open'] if is_macos else ['xdg-open']
    else:
        cmd = program
    return cmd


def open_cmd(cmd: Iterable[str] | list[str], arg: None | Iterable[str] | str = None,
             cwd: str | None = None, extra_env: dict[str, str] | None = None) -> 'PopenType[bytes]':
    import subprocess
    if arg is not None:
        cmd = list(cmd)
        if isinstance(arg, str):
            cmd.append(arg)
        else:
            cmd.extend(arg)
    env: dict[str, str] | None = None
    if extra_env:
        env = os.environ.copy()
        env.update(extra_env)
    return subprocess.Popen(
        tuple(cmd), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=cwd or None,
        preexec_fn=clear_handled_signals, env=env)


def open_url(url: str, program: str | list[str] = 'default', cwd: str | None = None, extra_env: dict[str, str] | None = None) -> 'PopenType[bytes]':
    return open_cmd(command_for_open(program), url, cwd=cwd, extra_env=extra_env)


def init_startup_notification_x11(window_handle: int, startup_id: str | None = None) -> Optional['StartupCtx']:
    # https://specifications.freedesktop.org/startup-notification-spec/startup-notification-latest.txt
    from kitty.fast_data_types import init_x11_startup_notification
    sid = startup_id or os.environ.pop('DESKTOP_STARTUP_ID', None)  # ensure child processes don't get this env var
    if not sid:
        return None
    from .fast_data_types import x11_display
    display = x11_display()
    if not display:
        return None
    return init_x11_startup_notification(display, window_handle, sid)


def end_startup_notification_x11(ctx: 'StartupCtx') -> None:
    from kitty.fast_data_types import end_x11_startup_notification
    end_x11_startup_notification(ctx)


def init_startup_notification(window_handle: int | None, startup_id: str | None = None) -> Optional['StartupCtx']:
    if is_macos or is_wayland():
        return None
    if window_handle is None:
        log_error('Could not perform startup notification as window handle not present')
        return None
    try:
        try:
            return init_startup_notification_x11(window_handle, startup_id)
        except OSError as e:
            if not str(e).startswith("Failed to load libstartup-notification"):
                raise e
            log_error(
                f'{e}. This has two main effects:',
                'There will be no startup feedback and when using --single-instance, kitty windows may start on an incorrect desktop/workspace.')
    except Exception:
        import traceback
        traceback.print_exc()
    return None


def end_startup_notification(ctx: Optional['StartupCtx']) -> None:
    if not ctx:
        return
    if is_macos or is_wayland():
        return
    try:
        end_startup_notification_x11(ctx)
    except Exception:
        import traceback
        traceback.print_exc()


class startup_notification_handler:

    # WARNING: This only works on X11 on other platforms extra_callback will be called
    # after the window is shown, not before, as they do not do two stage window
    # creation.

    def __init__(self, do_notify: bool = True, startup_id: str | None = None, extra_callback: Callable[[int], None] | None = None):
        self.do_notify = do_notify
        self.startup_id = startup_id
        self.extra_callback = extra_callback
        self.ctx: Optional['StartupCtx'] = None

    def __enter__(self) -> Callable[[int], None]:

        def pre_show_callback(window_handle: int) -> None:
            if self.extra_callback is not None:
                self.extra_callback(window_handle)
            if self.do_notify:
                self.ctx = init_startup_notification(window_handle, self.startup_id)

        return pre_show_callback

    def __exit__(self, *a: Any) -> None:
        if self.ctx is not None:
            end_startup_notification(self.ctx)


def unix_socket_directories() -> Iterator[str]:
    import tempfile
    home = os.path.expanduser('~')
    candidates = [tempfile.gettempdir(), home]
    if is_macos:
        from .fast_data_types import user_cache_dir
        candidates = [user_cache_dir(), '/Library/Caches']
    else:
        if os.environ.get('XDG_RUNTIME_DIR'):
            candidates.insert(0, os.environ['XDG_RUNTIME_DIR'])
    for loc in candidates:
        if os.access(loc, os.W_OK | os.R_OK | os.X_OK):
            yield loc


def unix_socket_paths(name: str, ext: str = '.lock') -> Generator[str, None, None]:
    home = os.path.expanduser('~')
    for loc in unix_socket_directories():
        filename = ('.' if loc == home else '') + name + ext
        yield os.path.join(loc, filename)


def parse_address_spec(spec: str) -> tuple[AddressFamily, tuple[str, int] | str, str | None]:
    import socket
    try:
        protocol, rest = spec.split(':', 1)
    except ValueError:
        raise ValueError(f'Invalid listen-on value: {spec} must be of the form protocol:address')
    socket_path = None
    address: str | tuple[str, int] = ''
    if protocol == 'unix':
        family = socket.AF_UNIX
        address = rest
        if address.startswith('@') and len(address) > 1:
            address = '\0' + address[1:]
        else:
            socket_path = address
    elif protocol in ('tcp', 'tcp6'):
        family = socket.AF_INET if protocol == 'tcp' else socket.AF_INET6
        if rest.startswith('['):  # ]
            host = rest[1:]
            host, sep, leftover = host.rpartition(']')
            _, port = leftover.rsplit(':', 1)
            if ':' in host and protocol == 'tcp':
                family = socket.AF_INET6
        else:
            host, port = rest.rsplit(':', 1)
        address = host, int(port)
    else:
        raise ValueError(f'Unknown protocol in listen-on value: {spec}')
    return family, address, socket_path


def parse_os_window_state(state: str) -> int:
    match state:
        case 'normal':
            return WINDOW_NORMAL
        case 'maximized':
            return WINDOW_MAXIMIZED
        case 'minimized':
            return WINDOW_MINIMIZED
        case 'fullscreen' | 'fullscreened':
            return WINDOW_FULLSCREEN
        case 'hidden':
            return WINDOW_HIDDEN
        case _:
            return WINDOW_NORMAL


def write_all(fd: int, data: str | bytes, block_until_written: bool = True) -> None:
    if isinstance(data, str):
        data = data.encode('utf-8')
    mvd = memoryview(data)
    while len(mvd) > 0:
        try:
            n = os.write(fd, mvd)
        except BlockingIOError:
            if not block_until_written:
                raise
            continue
        if not n:
            break
        mvd = mvd[n:]


class TTYIO:

    def __init__(self, read_with_timeout: bool = True):
        self.read_with_timeout = read_with_timeout

    def __enter__(self) -> 'TTYIO':
        self.tty_fd, self.original_termios = open_tty(self.read_with_timeout)
        return self

    def __exit__(self, *a: Any) -> None:
        from .fast_data_types import close_tty
        close_tty(self.tty_fd, self.original_termios)

    def wait_till_read_available(self) -> bool:
        if self.read_with_timeout:
            raise ValueError('Cannot wait when TTY is set to read with timeout')
        import select
        rd = select.select([self.tty_fd], [], [])[0]
        return bool(rd)

    def read(self, limit: int) -> bytes:
        return os.read(self.tty_fd, limit)

    def send(self, data: str | bytes | Iterable[str | bytes]) -> None:
        if isinstance(data, (str, bytes)):
            write_all(self.tty_fd, data)
        else:
            for chunk in data:
                write_all(self.tty_fd, chunk)

    def recv(self, more_needed: Callable[[bytes], bool], timeout: float, sz: int = 1) -> None:
        fd = self.tty_fd
        start_time = monotonic()
        while timeout > monotonic() - start_time:
            # will block for 0.1 secs waiting for data because we have set
            # VMIN=0 VTIME=1 in termios
            data = os.read(fd, sz)
            if data and not more_needed(data):
                break


def set_echo(fd: int = -1, on: bool = False) -> tuple[int, list[int | list[bytes | int]]]:
    import termios
    if fd < 0:
        fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    new = termios.tcgetattr(fd)
    if on:
        new[3] |= termios.ECHO
    else:
        new[3] &= ~termios.ECHO
    termios.tcsetattr(fd, termios.TCSADRAIN, new)
    return fd, old


@contextmanager
def no_echo(fd: int = -1) -> Iterator[None]:
    import termios
    fd, old = set_echo(fd)
    try:
        yield
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def natsort_ints(iterable: Iterable[str]) -> list[str]:

    def convert(text: str) -> int | str:
        return int(text) if text.isdigit() else text

    def alphanum_key(key: str) -> tuple[int | str, ...]:
        return tuple(map(convert, re.split(r'(\d+)', key)))

    return sorted(iterable, key=alphanum_key)


def get_hostname(fallback: str = '') -> str:
    import socket
    try:
        return socket.gethostname() or fallback
    except Exception:
        return fallback


def resolve_editor_cmd(editor: str, shell_env: Mapping[str, str]) -> str | None:
    import shlex
    editor_cmd = list(shlex_split(editor))
    editor_exe = (editor_cmd or ('',))[0]
    if editor_exe and os.path.isabs(editor_exe):
        return editor
    if not editor_exe:
        return None

    def patched(exe: str) -> str:
        editor_cmd[0] = exe
        return ' '.join(map(shlex.quote, editor_cmd))

    if shell_env is os.environ:
        q = which(editor_exe, only_system=True)
        if q:
            return patched(q)
    elif 'PATH' in shell_env:
        import shutil
        q = shutil.which(editor_exe, path=shell_env['PATH'])
        if q:
            return patched(q)
    return None


def get_editor_from_env(env: Mapping[str, str]) -> str | None:
    for var in ('VISUAL', 'EDITOR'):
        editor = env.get(var)
        if editor:
            editor = resolve_editor_cmd(editor, env)
            if editor:
                return editor
    return None


def get_editor_from_env_vars(opts: Options | None = None) -> list[str]:
    editor = get_editor_from_env(os.environ)
    if not editor:
        shell_env = read_shell_environment(opts)
        editor = get_editor_from_env(shell_env)

    for ans in (editor, 'vim', 'nvim', 'vi', 'emacs', 'hx', 'kak', 'micro', 'nano', 'vis'):
        if ans and which(next(shlex_split(ans)), only_system=True):
            break
    else:
        ans = 'vim'
    return list(shlex_split(ans))


def get_editor(opts: Options | None = None, path_to_edit: str = '', line_number: int = 0) -> list[str]:
    if opts is None:
        try:
            opts = get_options()
        except RuntimeError:
            # we are in a kitten
            from .cli import create_default_opts
            opts = create_default_opts()
    if opts.editor == '.':
        ans = get_editor_from_env_vars()
    else:
        ans = list(shlex_split(opts.editor))
    ans[0] = os.path.expanduser(ans[0])
    if path_to_edit:
        if line_number:
            eq = os.path.basename(ans[0]).lower()
            if eq in ('code', 'code.exe'):
                path_to_edit += f':{line_number}'
                ans.append('--goto')
            else:
                ans.append(f'+{line_number}')
        ans.append(path_to_edit)
    return ans


def is_path_in_temp_dir(path: str) -> bool:
    if not path:
        return False

    def abspath(x: str | None) -> str:
        if x:
            x = os.path.abspath(os.path.realpath(x))
        return x or ''

    import tempfile
    path = abspath(path)
    candidates = frozenset(map(abspath, ('/tmp', '/dev/shm', os.environ.get('TMPDIR', None), tempfile.gettempdir())))
    for q in candidates:
        if q and path.startswith(q):
            return True
    return False


def is_ok_to_read_image_file(path: str, fd: int) -> bool:
    import stat
    path = os.path.abspath(os.path.realpath(path))
    try:
        path_stat = os.stat(path, follow_symlinks=True)
        fd_stat = os.fstat(fd)
    except OSError:
        return False
    if not os.path.samestat(path_stat, fd_stat):
        return False
    parts = path.split(os.sep)[1:]
    if len(parts) < 1:
        return False
    if parts[0] in ('sys', 'proc', 'dev'):
        if parts[0] == 'dev':
            return len(parts) > 2 and parts[1] == 'shm'
        return False
    return stat.S_ISREG(fd_stat.st_mode)


def resolve_abs_or_config_path(path: str, env: Mapping[str, str] | None = None, conf_dir: str | None = None) -> str:
    path = os.path.expanduser(path)
    path = expandvars(path, env or {})
    if not os.path.isabs(path):
        path = os.path.join(conf_dir or config_dir, path)
    return path


def resolve_custom_file(path: str) -> str:
    opts: Options | None = None
    with suppress(RuntimeError):
        opts = get_options()
    return resolve_abs_or_config_path(path, opts.env if opts else {})


def func_name(f: Any) -> str:
    if hasattr(f, '__name__'):
        return str(f.__name__)
    if hasattr(f, 'func') and hasattr(f.func, '__name__'):
        return str(f.func.__name__)
    return str(f)


def resolved_shell(opts: Options | None = None) -> list[str]:
    q: str = getattr(opts, 'shell', '.')
    if q == '.':
        ans = [shell_path]
    else:
        env = {}
        if opts is not None:
            env['TERM'] = opts.term
        if 'SHELL' not in os.environ:
            env['SHELL'] = shell_path
        if 'HOME' not in os.environ:
            env['HOME'] = os.path.expanduser('~')
        if 'USER' not in os.environ:
            import pwd
            env['USER'] = pwd.getpwuid(os.geteuid()).pw_name
        def expand(x: str) -> str:
            return expandvars(x, env)
        ans = list(map(expand, shlex_split(q)))
    return ans


@run_once
def system_paths_on_macos() -> tuple[str, ...]:
    entries, seen = [], set()

    def add_from_file(x: str) -> None:
        try:
            f = open(x)
        except (FileNotFoundError, PermissionError):
            return
        with f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and line not in seen:
                    if os.path.isdir(line):
                        seen.add(line)
                        entries.append(line)
    try:
        files = os.listdir('/etc/paths.d')
    except (FileNotFoundError, PermissionError):
        files = []
    for name in sorted(files):
        add_from_file(os.path.join('/etc/paths.d', name))
    add_from_file('/etc/paths')
    return tuple(entries)


def which(name: str, only_system: bool = False) -> str | None:
    if os.sep in name:
        return name
    import shutil

    opts: Options | None = None
    with suppress(RuntimeError):
        opts = get_options()

    tried_paths = set()
    paths = []
    append_paths = []
    if opts and opts.exe_search_path:
        for x in opts.exe_search_path:
            x = x.strip()
            if x:
                if x[0] == '-':
                    tried_paths.add(os.path.expanduser(x[1:]))
                elif x[0] == '+':
                    append_paths.append(os.path.expanduser(x[1:]))
                else:
                    paths.append(os.path.expanduser(x))
    ep = os.environ.get('PATH')
    if ep:
        paths.extend(ep.split(os.pathsep))
    paths.append(os.path.expanduser('~/.local/bin'))
    paths.append(os.path.expanduser('~/bin'))
    paths.extend(append_paths)
    ans = shutil.which(name, path=os.pathsep.join(x for x in paths if x not in tried_paths))
    if ans:
        return ans
    # In case PATH is messed up try a default set of paths
    if is_macos:
        system_paths = system_paths_on_macos()
    else:
        system_paths = ('/usr/local/bin', '/opt/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin')
    tried_paths |= set(paths)
    system_paths = tuple(x for x in system_paths if x not in tried_paths)
    if system_paths:
        ans = shutil.which(name, path=os.pathsep.join(system_paths))
        if ans:
            return ans
        tried_paths |= set(system_paths)
    if only_system or opts is None:
        return None
    shell_env = read_shell_environment(opts)
    for xenv in (shell_env, opts.env):
        q = xenv.get('PATH')
        if q:
            paths = [x for x in xenv['PATH'].split(os.pathsep) if x not in tried_paths]
            ans = shutil.which(name, path=os.pathsep.join(paths))
            if ans:
                return ans
            tried_paths |= set(paths)
    return None


def read_shell_environment(opts: Options | None = None) -> dict[str, str]:
    ans: dict[str, str] | None = getattr(read_shell_environment, 'ans', None)
    if ans is None:
        from .child import openpty
        ans = {}
        setattr(read_shell_environment, 'ans', ans)
        import subprocess
        shell = resolved_shell(opts)
        master, slave = openpty()
        os.set_blocking(master, False)
        if '-l' not in shell and '--login' not in shell:
            shell += ['-l']
        if '-i' not in shell and '--interactive' not in shell:
            shell += ['-i']
        try:
            p = subprocess.Popen(
                shell + ['-c', 'env'], stdout=slave, stdin=slave, stderr=slave, start_new_session=True, close_fds=True,
                preexec_fn=clear_handled_signals)
        except FileNotFoundError:
            log_error('Could not find shell to read environment')
            return ans
        with os.fdopen(master, 'rb') as stdout, os.fdopen(slave, 'wb'):
            raw = b''
            from time import monotonic
            start_time = monotonic()
            while monotonic() - start_time < 1.5:
                try:
                    ret: int | None = p.wait(0.01)
                except subprocess.TimeoutExpired:
                    ret = None
                with suppress(Exception):
                    raw += stdout.read()
                if ret is not None:
                    break
            if cast(Optional[int], p.returncode) is None:
                log_error('Timed out waiting for shell to quit while reading shell environment')
                p.kill()
            elif p.returncode == 0:
                while True:
                    try:
                        x = stdout.read()
                    except Exception:
                        break
                    if not x:
                        break
                    raw += x
                draw = raw.decode('utf-8', 'replace')
                for line in draw.splitlines():
                    k, v = line.partition('=')[::2]
                    if k and v:
                        ans[k] = v
            else:
                log_error('Failed to run shell to read its environment')
    return ans


def parse_uri_list(text: str) -> Generator[str, None, None]:
    ' Get paths from file:// URLs '
    from urllib.parse import unquote, urlparse
    for line in text.splitlines():
        if not line or line.startswith('#'):
            continue
        if not line.startswith('file://'):
            yield line
            continue
        try:
            purl = urlparse(line, allow_fragments=False)
        except Exception:
            yield line
            continue
        if purl.path:
            yield unquote(purl.path)


def edit_config_file() -> None:
    from kitty.config import prepare_config_file_for_editing
    p = prepare_config_file_for_editing()
    editor = get_editor()
    os.execvp(editor[0], editor + [p])


class SSHConnectionData(NamedTuple):
    binary: str
    hostname: str
    port: int | None = None
    identity_file: str = ''
    extra_args: tuple[tuple[str, str], ...] = ()


def get_new_os_window_size(
    metrics: 'OSWindowSize', width: int, height: int, unit: str, incremental: bool = False, has_window_scaling: bool = True
) -> tuple[int, int]:
    if unit == 'cells':
        cw = metrics['cell_width']
        ch = metrics['cell_height']
        width *= cw
        height *= ch
        if has_window_scaling:
            width = round(width / metrics['xscale'])
            height = round(height / metrics['yscale'])
    if incremental:
        w = metrics['width'] + width
        h = metrics['height'] + height
    else:
        w = width or metrics['width']
        h = height or metrics['height']
    return w, h


def get_all_processes() -> Iterable[int]:
    if is_macos:
        from kitty.fast_data_types import get_all_processes as f
        yield from f()
    else:
        for c in os.listdir('/proc'):
            if c.isdigit():
                yield int(c)


def is_kitty_gui_cmdline(*cmd: str) -> bool:
    if not cmd:
        return False
    if os.path.basename(cmd[0]) != 'kitty':
        return False
    if len(cmd) == 1:
        return True
    s = cmd[1][:1]
    if s == '@':
        return False
    if s == '+':
        if cmd[1] == '+':
            return len(cmd) > 2 and cmd[2] == 'open'
        return cmd[1] == '+open'
    return True


def reload_conf_in_all_kitties() -> None:
    import signal

    from kitty.child import cmdline_of_pid

    for pid in get_all_processes():
        try:
            cmd = cmdline_of_pid(pid)
        except Exception:
            continue
        if cmd and is_kitty_gui_cmdline(*cmd):
            os.kill(pid, signal.SIGUSR1)


@run_once
def control_codes_pat() -> 'Pattern[str]':
    return re.compile('[\x00-\x09\x0b-\x1f\x7f-\x9f]')


def sanitize_control_codes(text: str, replace_with: str = '') -> str:
    return control_codes_pat().sub(replace_with, text)


def hold_till_enter() -> None:
    import subprocess

    from .constants import kitten_exe
    subprocess.Popen([kitten_exe(), '__hold_till_enter__']).wait()


def cleanup_ssh_control_masters() -> None:
    import glob
    import subprocess
    try:
        files = frozenset(glob.glob(os.path.join(runtime_dir(), ssh_control_master_template.format(
            kitty_pid=os.getpid(), ssh_placeholder='*'))))
    except OSError:
        return
    workers = tuple(subprocess.Popen([
        'ssh', '-o', f'ControlPath={x}', '-O', 'exit', 'kitty-unused-host-name'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        preexec_fn=clear_handled_signals) for x in files)
    for w in workers:
        w.wait()
    for x in files:
        with suppress(OSError):
            os.remove(x)


def path_from_osc7_url(url: str | bytes) -> str:
    if isinstance(url, bytes):
        url = url.decode('utf-8')
    if url.startswith('kitty-shell-cwd://'):
        return '/' + url.split('/', 3)[-1]
    if url.startswith('file://'):
        from urllib.parse import unquote, urlparse
        return unquote(urlparse(url).path)
    return ''


@run_once
def macos_version() -> tuple[int, ...]:
    # platform.mac_ver does not work thanks to Apple's stupid "hardening", so just use sw_vers
    import subprocess
    try:
        o = subprocess.check_output(['sw_vers', '-productVersion'], stderr=subprocess.STDOUT).decode()
    except Exception:
        return 0, 0, 0
    return tuple(map(int, o.strip().split('.')))


@lru_cache(maxsize=2)
def less_version(less_exe: str = 'less') -> int:
    import subprocess
    o = subprocess.check_output([less_exe, '-V'], stderr=subprocess.STDOUT).decode()
    m = re.match(r'less (\d+)', o)
    if m is None:
        raise ValueError(f'Invalid version string for less: {o}')
    return int(m.group(1))


def is_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except Exception:
        pass
    return True


def safer_fork() -> int:
    pid = os.fork()
    if pid:
        # master
        import ssl
        ssl.RAND_add(os.urandom(32), 0.0)
    else:
        # child
        import atexit
        atexit._clear()
    return pid


def docs_url(which: str = '', local_docs_root: str | None = '') -> str:
    from urllib.parse import quote

    from .conf.types import resolve_ref
    from .constants import local_docs, website_url
    if local_docs_root is None:
        ld = ''
    else:
        ld = local_docs_root or local_docs()
    base, frag = which.partition('#')[::2]
    base = base.strip('/')
    if frag.startswith('ref='):
        ref = frag[4:]
        which = resolve_ref(ref, lambda x: x)
        if which.startswith('https://') or which.startswith('http://'):
            return which
        base, frag = which.partition('#')[::2]
        base = base.strip('/')
    if ld:
        base = base or 'index'
        url = f'file://{ld}/' + quote(base) + '.html'
    else:
        url = website_url(base)
    if frag:
        url += '#' + frag
    return url


def sanitize_for_bracketed_paste(text: bytes) -> bytes:
    pat = re.compile(b'(?:(?:\033\\\x5b)|(?:\x9b))201~')
    while True:
        new_text = pat.sub(b'', text)
        if new_text == text:
            break
        text = new_text
    return text


@lru_cache(maxsize=64)
def sanitize_url_for_dispay_to_user(url: str) -> str:
    from urllib.parse import unquote, urlparse, urlunparse
    try:
        purl = urlparse(url)
        if purl.netloc:
            purl = purl._replace(netloc=purl.netloc.encode('idna').decode('ascii'))
        if purl.path:
            purl = purl._replace(path=unquote(purl.path))
        url = urlunparse(purl)
    except Exception as e:
        log_error(e)
        url = 'Unparseable URL: ' + url
    return url


def extract_all_from_tarfile_safely(tf: 'tarfile.TarFile', dest: str) -> None:
    # Ensure that all extracted items are within dest

    def is_within_directory(directory: str, target: str) -> bool:
        abs_directory = os.path.abspath(directory)
        abs_target = os.path.abspath(target)
        prefix = os.path.commonprefix((abs_directory, abs_target))
        return prefix == abs_directory

    def safe_extract(tar: 'tarfile.TarFile', path: str = ".", numeric_owner: bool = False) -> None:
        for member in tar.getmembers():
            member_path = os.path.join(path, member.name)
            if not is_within_directory(path, member_path):
                raise ValueError(f'Attempted path traversal in tar file: {member.name}')
        tar.extractall(path, tar.getmembers(), numeric_owner=numeric_owner)

    safe_extract(tf, dest)


def is_png(path: str) -> bool:
    if path:
        with suppress(Exception), open(path, 'rb') as f:
            header = f.read(8)
            return header.startswith(b'\211PNG\r\n\032\n')
    return False


def cmdline_for_hold(cmd: Sequence[str] = (), opts: Optional['Options'] = None) -> list[str]:
    if opts is None:
        with suppress(RuntimeError):
            opts = get_options()
    if opts is None:
        from .options.types import defaults
        opts = defaults
    ksi = ' '.join(opts.shell_integration)
    import shlex
    shell = shlex.join(resolved_shell(opts))
    return [kitten_exe(), 'run-shell', f'--shell={shell}', f'--shell-integration={ksi}', '--env=KITTY_HOLD=1'] + list(cmd)


def safe_mtime(path: str) -> float | None:
    with suppress(OSError):
        return os.path.getmtime(path)
    return None


@run_once
def get_custom_window_icon() -> tuple[float, str] | tuple[None, None]:
    filenames = ['kitty.app.png']
    if is_macos:
        # On macOS, prefer icns to png.
        filenames.insert(0, 'kitty.app.icns')
    for name in filenames:
        custom_icon_path = os.path.join(config_dir, name)
        custom_icon_mtime = safe_mtime(custom_icon_path)
        if custom_icon_mtime is not None:
            return custom_icon_mtime, custom_icon_path
    return None, None


def key_val_matcher(items: Iterable[tuple[str, str]], key_pat: 're.Pattern[str]', val_pat: Optional['re.Pattern[str]']) -> bool:
    for key, val in items:
        if key_pat.search(key) is not None and (
                val_pat is None or val_pat.search(val) is not None):
            return True
    return False


def shlex_split(text: str, allow_ansi_quoted_strings: bool = False) -> Iterator[str]:
    yield from Shlex(text, allow_ansi_quoted_strings)


def shlex_split_with_positions(text: str, allow_ansi_quoted_strings: bool = False) -> Iterator[tuple[int, str]]:
    s = Shlex(text, allow_ansi_quoted_strings)
    while (q := s.next_word())[0] > -1:
        yield q


def timed_debug_print(*a: Any, sep: str = ' ', end: str = '\n') -> None:
    _timed_debug_print(sep.join(map(str, a)) + end)


def lock_file(f: BinaryIO) -> None:
    if not f.writable():
        raise ValueError('Cannot lock files not opened in writable mode')
    fcntl.lockf(f, fcntl.LOCK_EX)


def unlock_file(f: BinaryIO) -> None:
    if not f.writable():
        raise ValueError('Cannot unlock files not opened in writable mode')
    fcntl.lockf(f, fcntl.LOCK_UN)

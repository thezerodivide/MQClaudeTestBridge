"""Configuration for the MCP server: the named constants, the --config argument and config.toml loading.

DL-022 addenda of 2026-10-04: decision 18 (this module reads config.toml with tomllib and holds the named constants in
one documented block; it imports only the standard library), decision 19 (the explicit --config <absolute path>
argument and the four refusal kinds), decision 20 (every key has an overridable code default, so an empty file is
valid), decision 21 (value validation; the first failure only). Pure apart from reading the one file it is given.

Every refusal is a ConfigError with a `kind`. format_refusal and write_refusal turn it into one printable-ASCII line
for stderr (never stdout, which carries MCP traffic). External text (a path, a key name) is escaped with
json.dumps(value, ensure_ascii=True), the rule of DL-021 item 23.
"""
import json
import math
import pathlib
import tomllib
from dataclasses import dataclass

# ---------------------------------------------------------------------------------------------------------------------
# Constants. Two labelled sections; none of these is a config.toml key.
# ---------------------------------------------------------------------------------------------------------------------

# --- Fixed safety limit (not a first guess; changing it is a requirement change, not a tuning) ----------------------

# The longest expression, in bytes, that may reach mq.parse (criterion 12). Evidence: spike 6b (DL-020), an input of
# exactly 2048 bytes crashed the whole EverQuest client, while 2000, 2046 and 2047 bytes worked. The likely cause (a
# fixed 2048-byte buffer copy) is a reading of the source, not a confirmed explanation. No revisit trigger.
EXPRESSION_LIMIT_BYTES = 2047

# --- Tunable first guesses (Protocol section 15; each with its evidence and revisit trigger) ------------------------

# The largest request file, in bytes, the server will publish (DL-021). Revisit trigger: a legitimate request refused
# for size, or the bridge's own limit changing.
REQUEST_LIMIT_BYTES = 32768

# Heartbeat read retry: transient sharing or access failures only (DL-021 timing values, 2026-09-29). Evidence: spike 9
# (run-length of open failures, longest about 10 ms under stress). Revisit trigger: a heartbeat read that still fails
# after the retries in live use.
HEARTBEAT_READ_ATTEMPTS = 5
HEARTBEAT_READ_INTERVAL_S = 0.02

# Timeout of the `tasklist` process check (DL-021 timing values). Evidence: 60 timed runs, maximum 102 ms. Revisit
# trigger: a `tasklist` timeout seen in live use.
TASKLIST_TIMEOUT_S = 5

# --- Defaults of the config.toml keys (decision 20), for the confirmed v1 installation ------------------------------

# The MacroQuest root (SPEC, lines 28, 30 and 65). Overridable in effect through bridge_dir and log_dir. Revisit
# trigger: before a public release (Phase 4), or the first install in a non-default location.
MACROQUEST_ROOT = 'C:\\Users\\Public\\MacroQuest'

DEFAULT_BRIDGE_DIR = MACROQUEST_ROOT + '\\claude'
DEFAULT_LOG_DIR = MACROQUEST_ROOT + '\\Logs\\claudebridge'
DEFAULT_HEARTBEAT_MAX_AGE_S = 20
DEFAULT_REPLY_TIMEOUT_S = 30
DEFAULT_GAME_PROCESS_NAME = 'eqgame.exe'

PREFIX = 'mq_mcp refused to start: '  # equals version.PREFIX (a test checks it; this module imports only the stdlib)

_PATH_KEYS = ('bridge_dir', 'log_dir')
_NUMBER_KEYS = ('heartbeat_max_age_s', 'reply_timeout_s')
_KEYS = ('bridge_dir', 'log_dir', 'heartbeat_max_age_s', 'reply_timeout_s', 'game_process_name')


class ConfigError(Exception):
    """A refusal to start. `kind` is one of argument_missing, path_not_absolute, file_unreadable, toml_malformed,
    unknown_key, invalid_value; `message` is a fixed sentence with any external text already escaped."""

    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind
        self.message = message


@dataclass(frozen=True)
class Config:
    path: str
    bridge_dir: str
    log_dir: str
    heartbeat_max_age_s: float
    reply_timeout_s: float
    game_process_name: str


def _escape(value):
    return json.dumps(value, ensure_ascii=True)


def is_absolute_windows_path(path):
    """True for a drive-letter path, a UNC share or an extended-length path; False for a relative path, a rooted path
    without a drive (\\x), a drive-relative path (C:x), '.' and ''. Never resolved against the working directory."""
    return isinstance(path, str) and pathlib.PureWindowsPath(path).is_absolute()


def parse_args(argv):
    """Return the value that follows the first '--config' in argv (the arguments after the program name). Other
    elements are ignored. Raises ConfigError('argument_missing') when '--config' or its value is absent."""
    for index, element in enumerate(argv):
        if element == '--config':
            if index + 1 < len(argv):
                return argv[index + 1]
            break
    raise ConfigError('argument_missing', 'the --config argument and an absolute path to config.toml are required.')


def _check_path_key(key, value):
    if not is_absolute_windows_path(value):  # False for a non-string
        raise ConfigError('invalid_value', 'the value of ' + _escape(key) + ' must be an absolute Windows path string.')
    return value


def _check_number_key(key, value):
    # bool is an int subclass, so it is excluded first. An int is never passed to math.isfinite: a huge int raises
    # OverflowError there.
    ok = isinstance(value, (int, float)) and not isinstance(value, bool)
    if ok and isinstance(value, float):
        ok = math.isfinite(value)
    if ok:
        ok = value > 0
    if not ok:
        raise ConfigError('invalid_value',
                          'the value of ' + _escape(key) + ' must be a finite number greater than zero.')
    return value


def _check_name_key(key, value):
    if not isinstance(value, str) or not value.strip():
        raise ConfigError('invalid_value', 'the value of ' + _escape(key) + ' must be a string that is not blank.')
    return value


def validate(table, path):
    """Decision 21: refuse an unknown key, then check each present value; apply the defaults (decision 20). Only the
    first failure is raised. `path` is recorded in the result."""
    for key in table:
        if key not in _KEYS:
            raise ConfigError('unknown_key', 'config.toml has an unknown key ' + _escape(key) + '.')
    values = {
        'bridge_dir': DEFAULT_BRIDGE_DIR,
        'log_dir': DEFAULT_LOG_DIR,
        'heartbeat_max_age_s': DEFAULT_HEARTBEAT_MAX_AGE_S,
        'reply_timeout_s': DEFAULT_REPLY_TIMEOUT_S,
        'game_process_name': DEFAULT_GAME_PROCESS_NAME,
    }
    for key in _KEYS:
        if key not in table:
            continue
        if key in _PATH_KEYS:
            values[key] = _check_path_key(key, table[key])
        elif key in _NUMBER_KEYS:
            values[key] = _check_number_key(key, table[key])
        else:
            values[key] = _check_name_key(key, table[key])
    return Config(path=path, **values)


def load(path):
    """Read and validate the config.toml at the explicit absolute `path`. A relative path is refused, never resolved
    against the working directory."""
    if not is_absolute_windows_path(path):
        raise ConfigError('path_not_absolute', 'the --config path ' + _escape(path) + ' is not an absolute path.')
    try:
        with open(path, 'rb') as handle:
            raw = handle.read()
    except (OSError, ValueError) as error:  # ValueError: a path with an embedded NUL
        raise ConfigError('file_unreadable',
                          'the config file ' + _escape(path) + ' could not be read (' + type(error).__name__ + ').')
    try:
        table = tomllib.loads(raw.decode('utf-8'))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as error:
        raise ConfigError('toml_malformed',
                          'the config file ' + _escape(path) + ' is not valid TOML (' + type(error).__name__ + ').')
    return validate(table, path)


def load_from_args(argv):
    """parse_args then load: the one call the server's main() makes."""
    return load(parse_args(argv))


def format_refusal(error):
    """The one stderr line for a ConfigError: printable ASCII, no line break."""
    return PREFIX + error.message


def write_refusal(error, stream):
    """Write format_refusal(error) and a newline to `stream` only (the caller passes stderr, never stdout)."""
    stream.write(format_refusal(error) + '\n')

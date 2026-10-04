"""Tests for mq_mcp/config.py.

Requirement sources (DL-022 addenda of 2026-10-04, docs/decision_log.md):
  decision 18: config.py holds the named constants, in one block; it imports only the standard library;
  decision 19: the explicit --config <absolute path> argument; a missing argument, a relative / drive-relative / empty
    path, an unreadable or missing file, or malformed TOML (including a duplicate key) is a refusal with its own kind;
    one escaped ASCII line, written only to the stream it is given; a relative path is never resolved against the
    working directory; a path with spaces is one argument element;
  decision 20: every key has an overridable code default, so an empty file is valid, and config.example.toml lists
    every key with that same default;
  decision 21: unknown keys are refused; bridge_dir and log_dir are absolute Windows paths (UNC, extended-length and
    drive paths all classify as absolute, which is the rule's classification only, not evidence that a UNC bridge
    folder works); game_process_name is a non-blank string; the two timeouts are an int or float, not a bool, finite
    and greater than zero; the first failure only, as unknown_key or invalid_value naming the key;
  DL-020 / criterion 12: the expression limit is exactly 2047 bytes.
"""
import io
import os
import pathlib
import re
import sys
import tempfile
import unittest
from unittest import mock

from mq_mcp import config, version

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
BACKSLASH = chr(92)


def one_ascii_line(text):
    return re.fullmatch(r'[\x20-\x7e]*', text) is not None


class Workspace(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix='mq mcp config ')
        self.addCleanup(self._tmp.cleanup)
        self.dir = self._tmp.name

    def write(self, text, name='config.toml', mode='w'):
        path = os.path.join(self.dir, name)
        if mode == 'wb':
            with open(path, 'wb') as handle:
                handle.write(text)
        else:
            with open(path, 'w', encoding='utf-8', newline='') as handle:
                handle.write(text)
        return path

    def refused(self, text, kind):
        path = self.write(text)
        with self.assertRaises(config.ConfigError) as caught:
            config.load(path)
        self.assertEqual(caught.exception.kind, kind)
        return caught.exception


class Constants(unittest.TestCase):
    def test_expression_limit_is_exactly_2047_bytes(self):  # DL-020, criterion 12
        self.assertEqual(config.EXPRESSION_LIMIT_BYTES, 2047)

    def test_tunable_first_guesses(self):  # decision 18 design choice 3; DL-021 timing values
        self.assertEqual(config.REQUEST_LIMIT_BYTES, 32768)
        self.assertEqual(config.HEARTBEAT_READ_ATTEMPTS, 5)
        self.assertEqual(config.HEARTBEAT_READ_INTERVAL_S, 0.02)
        self.assertEqual(config.TASKLIST_TIMEOUT_S, 5)

    def test_defaults_derive_from_the_documented_root(self):  # decision 20 design choice 1
        self.assertEqual(config.MACROQUEST_ROOT, 'C:' + BACKSLASH + 'Users' + BACKSLASH + 'Public' + BACKSLASH
                         + 'MacroQuest')
        self.assertEqual(config.DEFAULT_BRIDGE_DIR, config.MACROQUEST_ROOT + BACKSLASH + 'claude')
        self.assertEqual(config.DEFAULT_LOG_DIR,
                         config.MACROQUEST_ROOT + BACKSLASH + 'Logs' + BACKSLASH + 'claudebridge')

    def test_refusal_prefix_equals_the_version_modules(self):  # config imports only the stdlib, so it repeats it
        self.assertEqual(config.PREFIX, version.PREFIX)

    def test_imports_only_the_standard_library(self):  # decision 18 design choice 2
        source = (REPO_ROOT / 'python' / 'mq_mcp' / 'config.py').read_text(encoding='utf-8')
        imported = set(re.findall(r'^(?:import|from)\s+([A-Za-z_][A-Za-z0-9_]*)', source, re.MULTILINE))
        self.assertTrue(imported <= set(sys.stdlib_module_names), imported - set(sys.stdlib_module_names))


class ParseArgs(unittest.TestCase):
    def test_returns_the_element_after_config(self):  # decision 19
        self.assertEqual(config.parse_args(['--config', 'C:/x/config.toml']), 'C:/x/config.toml')

    def test_a_path_with_spaces_is_one_element(self):  # decision 19 implementation choices
        path = 'C:' + BACKSLASH + 'My Files' + BACKSLASH + 'config.toml'
        self.assertEqual(config.parse_args(['--config', path]), path)

    def test_missing_argument_is_refused(self):
        for argv in ([], ['--other', 'x'], ['--config']):
            with self.assertRaises(config.ConfigError) as caught:
                config.parse_args(argv)
            self.assertEqual(caught.exception.kind, 'argument_missing')

    def test_other_elements_are_ignored(self):
        self.assertEqual(config.parse_args(['-v', '--config', 'C:/x.toml', 'extra']), 'C:/x.toml')


class AbsolutePaths(unittest.TestCase):
    def test_absolute_forms(self):  # decision 19 verified probe; decision 21 UNC / extended-length probe
        for path in ('C:/a/b', 'C:' + BACKSLASH + 'a', BACKSLASH * 2 + 'server' + BACKSLASH + 'share' + BACKSLASH + 'd',
                     BACKSLASH * 2 + '?' + BACKSLASH + 'C:' + BACKSLASH + 'dir'):
            self.assertTrue(config.is_absolute_windows_path(path), path)

    def test_not_absolute_forms(self):  # decision 19: C:a, rooted without a drive, relative, '.', ''
        for path in ('C:a', BACKSLASH + 'a', 'a' + BACKSLASH + 'b', 'config.toml', '.', '', None, 5):
            self.assertFalse(config.is_absolute_windows_path(path), repr(path))


class LoadFile(Workspace):
    def test_empty_file_gives_every_default(self):  # decision 20 design choice 2
        cfg = config.load(self.write(''))
        self.assertEqual(cfg.bridge_dir, 'C:' + BACKSLASH + 'Users' + BACKSLASH + 'Public' + BACKSLASH
                         + 'MacroQuest' + BACKSLASH + 'claude')
        self.assertEqual(cfg.log_dir, 'C:' + BACKSLASH + 'Users' + BACKSLASH + 'Public' + BACKSLASH + 'MacroQuest'
                         + BACKSLASH + 'Logs' + BACKSLASH + 'claudebridge')
        self.assertEqual(cfg.heartbeat_max_age_s, 20)  # approved timing value, decision 20
        self.assertEqual(cfg.reply_timeout_s, 30)
        self.assertEqual(cfg.game_process_name, 'eqgame.exe')

    def test_the_loaded_path_is_recorded(self):  # DL-021 item 23: the startup line records the config file path
        path = self.write('')
        self.assertEqual(config.load(path).path, path)

    def test_each_key_overrides_its_default(self):  # decision 20 design choice 3
        path = self.write(
            "bridge_dir = 'D:\\\\bridge'\n".replace('\\\\', BACKSLASH)
            + "log_dir = 'D:\\\\logs'\n".replace('\\\\', BACKSLASH)
            + 'heartbeat_max_age_s = 7.5\nreply_timeout_s = 12\ngame_process_name = "other.exe"\n')
        cfg = config.load(path)
        self.assertEqual(cfg.bridge_dir, 'D:' + BACKSLASH + 'bridge')
        self.assertEqual(cfg.log_dir, 'D:' + BACKSLASH + 'logs')
        self.assertEqual(cfg.heartbeat_max_age_s, 7.5)
        self.assertEqual(cfg.reply_timeout_s, 12)
        self.assertEqual(cfg.game_process_name, 'other.exe')

    def test_a_single_override_keeps_the_other_defaults(self):
        cfg = config.load(self.write('reply_timeout_s = 99\n'))
        self.assertEqual(cfg.reply_timeout_s, 99)
        self.assertEqual(cfg.heartbeat_max_age_s, 20)
        self.assertEqual(cfg.game_process_name, 'eqgame.exe')

    def test_a_path_containing_spaces_loads(self):  # decision 19: the temp folder name contains spaces
        self.assertIn(' ', self.dir)
        config.load(self.write(''))

    def test_example_file_lists_every_key_with_its_default(self):  # decision 20 implementation choices
        import tomllib
        table = tomllib.loads((REPO_ROOT / 'config.example.toml').read_text(encoding='utf-8'))
        self.assertEqual(table, {
            'bridge_dir': config.DEFAULT_BRIDGE_DIR,
            'log_dir': config.DEFAULT_LOG_DIR,
            'heartbeat_max_age_s': config.DEFAULT_HEARTBEAT_MAX_AGE_S,
            'reply_timeout_s': config.DEFAULT_REPLY_TIMEOUT_S,
            'game_process_name': config.DEFAULT_GAME_PROCESS_NAME,
        })

    def test_example_file_loads_to_the_defaults(self):
        cfg = config.load(str(REPO_ROOT / 'config.example.toml'))
        self.assertEqual(cfg.bridge_dir, config.DEFAULT_BRIDGE_DIR)
        self.assertEqual(cfg.reply_timeout_s, config.DEFAULT_REPLY_TIMEOUT_S)


class WorkingDirectory(Workspace):
    def test_relative_path_is_refused_even_when_the_file_exists_relative_to_the_cwd(self):  # decision 19
        self.write('')
        old = os.getcwd()
        os.chdir(self.dir)
        self.addCleanup(os.chdir, old)
        with self.assertRaises(config.ConfigError) as caught:
            config.load('config.toml')
        self.assertEqual(caught.exception.kind, 'path_not_absolute')

    def test_absolute_path_works_from_an_unrelated_cwd(self):  # decision 19 implementation choices
        path = self.write('')
        other = tempfile.TemporaryDirectory()
        self.addCleanup(other.cleanup)
        old = os.getcwd()
        os.chdir(other.name)
        self.addCleanup(os.chdir, old)
        self.assertEqual(config.load(path).game_process_name, 'eqgame.exe')

    def test_drive_relative_rooted_and_empty_paths_are_refused(self):  # decision 19
        for path in ('C:config.toml', BACKSLASH + 'config.toml', ''):
            with self.assertRaises(config.ConfigError) as caught:
                config.load(path)
            self.assertEqual(caught.exception.kind, 'path_not_absolute', repr(path))


class UnreadableAndMalformed(Workspace):
    def test_missing_file(self):  # decision 19
        with self.assertRaises(config.ConfigError) as caught:
            config.load(os.path.join(self.dir, 'nope.toml'))
        self.assertEqual(caught.exception.kind, 'file_unreadable')

    def test_a_directory_is_unreadable(self):
        with self.assertRaises(config.ConfigError) as caught:
            config.load(self.dir)
        self.assertEqual(caught.exception.kind, 'file_unreadable')

    def test_a_path_with_an_embedded_nul_is_unreadable_not_a_crash(self):
        with self.assertRaises(config.ConfigError) as caught:
            config.load('C:' + BACKSLASH + 'a\x00b.toml')
        self.assertEqual(caught.exception.kind, 'file_unreadable')

    def test_malformed_toml(self):
        self.refused('this is = = not toml\n', 'toml_malformed')

    def test_duplicate_key_is_malformed_toml(self):  # decision 21 verified: a duplicate key is a TOMLDecodeError
        self.refused('reply_timeout_s = 1\nreply_timeout_s = 2\n', 'toml_malformed')

    def test_invalid_utf8_is_malformed_toml(self):
        path = self.write(b'game_process_name = "\xff\xfe"\n', mode='wb')
        with self.assertRaises(config.ConfigError) as caught:
            config.load(path)
        self.assertEqual(caught.exception.kind, 'toml_malformed')


class ValueValidation(Workspace):
    def test_unknown_key_is_refused_and_named(self):  # decision 21 design choice 1
        error = self.refused('bogus = 1\n', 'unknown_key')
        self.assertIn('"bogus"', error.message)

    def test_a_misspelled_known_key_is_refused(self):
        error = self.refused('reply_timeout = 5\n', 'unknown_key')
        self.assertIn('reply_timeout', error.message)

    def test_wrong_types_are_refused_for_every_key(self):  # decision 21 design choices 2 to 4
        cases = {
            'bridge_dir': ('5', 'true', '[1]'),
            'log_dir': ('5', 'true'),
            'heartbeat_max_age_s': ('"20"', '[1]', '1979-05-27'),
            'reply_timeout_s': ('"30"', '{a = 1}'),
            'game_process_name': ('5', 'true', '[1]'),
        }
        for key, values in cases.items():
            for value in values:
                error = self.refused(key + ' = ' + value + '\n', 'invalid_value')
                self.assertIn(key, error.message)

    def test_a_bool_is_not_a_number(self):  # decision 21 verified: bool is an int instance
        self.refused('heartbeat_max_age_s = true\n', 'invalid_value')
        self.refused('reply_timeout_s = false\n', 'invalid_value')

    def test_inf_and_nan_are_refused(self):  # decision 21 verified: both are valid TOML floats
        for value in ('inf', '-inf', 'nan'):
            self.refused('reply_timeout_s = ' + value + '\n', 'invalid_value')
            self.refused('heartbeat_max_age_s = ' + value + '\n', 'invalid_value')

    def test_zero_and_negative_are_refused(self):
        for value in ('0', '0.0', '-1', '-0.5'):
            self.refused('reply_timeout_s = ' + value + '\n', 'invalid_value')

    def test_a_small_positive_float_and_a_huge_int_are_accepted(self):  # decision 21: no upper bound
        cfg = config.load(self.write('reply_timeout_s = 0.001\nheartbeat_max_age_s = 1' + '0' * 400 + '\n'))
        self.assertEqual(cfg.reply_timeout_s, 0.001)
        self.assertEqual(cfg.heartbeat_max_age_s, 10 ** 400)

    def test_no_relation_between_the_two_timeouts_is_enforced(self):  # decision 21 design choice 4
        cfg = config.load(self.write('heartbeat_max_age_s = 100\nreply_timeout_s = 1\n'))
        self.assertEqual((cfg.heartbeat_max_age_s, cfg.reply_timeout_s), (100, 1))

    def test_blank_process_names_are_refused(self):  # decision 21 design choice 3
        self.refused('game_process_name = ""\n', 'invalid_value')
        self.refused('game_process_name = "   "\n', 'invalid_value')

    def test_any_nonblank_process_name_is_accepted(self):
        self.assertEqual(config.load(self.write('game_process_name = "My Game 2.exe"\n')).game_process_name,
                         'My Game 2.exe')

    def test_relative_and_drive_relative_directories_are_refused(self):  # decision 21 design choice 2
        for value in ("'rel'", "'C:rel'", "''", "'" + BACKSLASH + "rooted'"):
            self.refused('bridge_dir = ' + value + '\n', 'invalid_value')
            self.refused('log_dir = ' + value + '\n', 'invalid_value')

    def test_unc_extended_length_and_drive_directories_are_accepted(self):  # classification only
        for value in (BACKSLASH * 2 + 'server' + BACKSLASH + 'share' + BACKSLASH + 'dir',
                      BACKSLASH * 2 + '?' + BACKSLASH + 'C:' + BACKSLASH + 'dir', 'C:/forward/slashes'):
            cfg = config.load(self.write("bridge_dir = '" + value + "'\n"))
            self.assertEqual(cfg.bridge_dir, value)

    def test_directories_are_not_checked_for_existence(self):  # decision 21 design choice 2
        cfg = config.load(self.write("bridge_dir = 'Z:\\no\\such\\folder'\n"))
        self.assertEqual(cfg.bridge_dir, 'Z:' + BACKSLASH + 'no' + BACKSLASH + 'such' + BACKSLASH + 'folder')

    def test_only_the_first_failure_is_reported(self):  # decision 21 design choice 5
        path = self.write('reply_timeout_s = -1\nheartbeat_max_age_s = "x"\ngame_process_name = ""\n')
        with self.assertRaises(config.ConfigError) as caught:
            config.load(path)
        named = [key for key in ('reply_timeout_s', 'heartbeat_max_age_s', 'game_process_name')
                 if key in caught.exception.message]
        self.assertEqual(len(named), 1)


class Refusal(Workspace):
    def test_line_has_the_prefix_and_the_message(self):  # decision 19 design choice 3
        error = config.ConfigError('invalid_value', 'a fixed sentence.')
        self.assertEqual(config.format_refusal(error), 'mq_mcp refused to start: a fixed sentence.')

    def test_hostile_unknown_key_becomes_one_ascii_line(self):  # decision 19 / 21 implementation choices
        hostile = 'bad\\nkey\\u00e9\\t\\u001b[0m\\ud7ff'  # TOML escapes: a newline, an accent, a tab, ESC, a code point
        error = self.refused('"' + hostile + '" = 1\n', 'unknown_key')
        line = config.format_refusal(error)
        self.assertTrue(one_ascii_line(line), repr(line))

    def test_hostile_path_becomes_one_ascii_line(self):
        error = None
        try:
            config.load('rel\native\x1b\u00e9\x7f')
        except config.ConfigError as caught:
            error = caught
        self.assertEqual(error.kind, 'path_not_absolute')
        self.assertTrue(one_ascii_line(config.format_refusal(error)), repr(config.format_refusal(error)))

    def test_hostile_unreadable_path_becomes_one_ascii_line(self):
        hostile = os.path.join(self.dir, 'missing\u00e9\x7f.toml')
        with self.assertRaises(config.ConfigError) as caught:
            config.load(hostile)
        self.assertTrue(one_ascii_line(config.format_refusal(caught.exception)))

    def test_write_refusal_writes_only_to_the_given_stream(self):  # decision 19: stderr, never stdout
        error = config.ConfigError('argument_missing', 'x.')
        target, out = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, 'stdout', out):
            config.write_refusal(error, target)
        self.assertEqual(target.getvalue(), 'mq_mcp refused to start: x.\n')
        self.assertEqual(out.getvalue(), '')

    def test_load_from_args_end_to_end(self):
        path = self.write('reply_timeout_s = 11\n')
        self.assertEqual(config.load_from_args(['--config', path]).reply_timeout_s, 11)
        with self.assertRaises(config.ConfigError) as caught:
            config.load_from_args([])
        self.assertEqual(caught.exception.kind, 'argument_missing')


if __name__ == '__main__':
    unittest.main()

"""Tests for mq_mcp/version.py (Python side of the build identity).

Requirement sources:
  DL-021 design item 22: a versioned entry script mq_mcp-<version>.py whose filename version must equal the version
    module's, refusing to start on a mismatch; a plain mq_mcp.py is a release entry and requires a non-test version;
  DL-021 design item 27: the entry compares sys.version_info[:3] with the PYTHON_VERSION captured in its own snapshot
    and refuses to start on a mismatch;
  DL-021 design item 20: our own messages are printable ASCII by construction (a file name is external text);
  Protocol section 9: SemVer, with -test.N pre-release identifiers for test builds.
check_entry and check_python return (ok, message); message is '' when ok is True.
"""
import re
import unittest

from mq_mcp import version


def printable_ascii(text):
    return re.search(r'[^\x20-\x7e]', text) is None


class EntryFilename(unittest.TestCase):
    def test_matching_versioned_entry_is_allowed(self):
        ok, msg = version.check_entry('C:/repo/python/dist/0.1.0-test.1/mq_mcp-0.1.0-test.1.py', '0.1.0-test.1')
        self.assertTrue(ok)
        self.assertEqual(msg, '')

    def test_backslash_path_is_handled(self):
        ok, _ = version.check_entry('C:' + chr(92) + 'repo' + chr(92) + 'dist' + chr(92) + 'mq_mcp-0.1.0-test.1.py',
                                    '0.1.0-test.1')
        self.assertTrue(ok)

    def test_filename_version_that_differs_refuses_and_names_both_versions(self):
        ok, msg = version.check_entry('C:/repo/dist/mq_mcp-0.1.0-test.2.py', '0.1.0-test.1')
        self.assertFalse(ok)
        self.assertIn('mq_mcp refused to start', msg)
        self.assertIn('0.1.0-test.2', msg)
        self.assertIn('0.1.0-test.1', msg)

    def test_plain_entry_is_allowed_only_for_a_release_version(self):
        ok, _ = version.check_entry('C:/repo/dist/mq_mcp.py', '0.1.0')
        self.assertTrue(ok)

    def test_plain_entry_with_a_test_version_refuses_and_names_the_version(self):
        ok, msg = version.check_entry('C:/repo/dist/mq_mcp.py', '0.1.0-test.1')
        self.assertFalse(ok)
        self.assertIn('mq_mcp refused to start', msg)
        self.assertIn('0.1.0-test.1', msg)

    def test_unrecognised_entry_names_refuse(self):
        for name in ('other.py', 'mq_mcp-.py', 'mq_mcp.py.bak', 'mq_mcp_0.1.0-test.1.py'):
            with self.subTest(name=name):
                ok, msg = version.check_entry('C:/repo/dist/' + name, '0.1.0-test.1')
                self.assertFalse(ok)
                self.assertIn('mq_mcp refused to start', msg)
                self.assertIn(name, msg)

    def test_message_is_printable_ascii_for_odd_file_names(self):
        for name in ('mq_mcp-0.1.0-\u00e9.py', 'mq_\x01\u00ff.py'):
            with self.subTest(name=name):
                ok, msg = version.check_entry('C:/repo/dist/' + name, '0.1.0-test.1')
                self.assertFalse(ok)
                self.assertTrue(printable_ascii(msg), msg)
                self.assertNotIn('\u00e9', msg)
                self.assertNotIn('\u00ff', msg)


class InterpreterVersion(unittest.TestCase):
    def test_exact_match_is_allowed(self):
        ok, msg = version.check_python('3.14.7', (3, 14, 7))
        self.assertTrue(ok)
        self.assertEqual(msg, '')

    def test_a_trailing_newline_in_the_captured_file_is_allowed(self):
        ok, _ = version.check_python('3.14.7\n', (3, 14, 7))
        self.assertTrue(ok)

    def test_a_patch_level_difference_refuses_and_names_both_versions(self):
        ok, msg = version.check_python('3.14.7', (3, 14, 8))
        self.assertFalse(ok)
        self.assertIn('mq_mcp refused to start', msg)
        self.assertIn('3.14.7', msg)
        self.assertIn('3.14.8', msg)

    def test_a_requirement_that_is_not_x_y_z_refuses(self):
        for required in ('3.14', '3.14.7.1', 'three', ''):
            with self.subTest(required=required):
                ok, msg = version.check_python(required, (3, 14, 7))
                self.assertFalse(ok)
                self.assertIn('mq_mcp refused to start', msg)

    def test_message_is_printable_ascii_for_an_odd_requirement(self):
        ok, msg = version.check_python('3.14.\u00e9', (3, 14, 7))
        self.assertFalse(ok)
        self.assertTrue(printable_ascii(msg), msg)

    def test_a_requirement_written_with_non_ascii_digits_is_refused(self):
        # int() accepts other scripts' digits, so a non-ASCII 7 would otherwise read as 3.14.7. Found while tightening
        # the version checks for step 1 (not in the reviewer's list).
        ok, msg = version.check_python('3.14.\u0667', (3, 14, 7))
        self.assertFalse(ok)
        self.assertIn('mq_mcp refused to start', msg)
        self.assertTrue(printable_ascii(msg), msg)

    def test_a_sys_version_info_style_object_is_accepted(self):
        import sys
        required = '%d.%d.%d' % tuple(sys.version_info[:3])
        ok, _ = version.check_python(required, sys.version_info)
        self.assertTrue(ok)


class VersionValue(unittest.TestCase):
    def test_is_test_is_true_only_for_a_well_formed_test_version(self):
        self.assertTrue(version.is_test('0.1.0-test.4'))
        self.assertTrue(version.is_test('12.0.3-test.0'))
        self.assertFalse(version.is_test('0.1.0'))
        self.assertFalse(version.is_test('1.0.0-rc.1'))

    def test_malformed_lookalikes_are_neither_test_nor_release(self):
        # Protocol section 9 (SemVer, -test.N for test builds); found in the second reviewer's read of step 1.
        for v in ('0.1.0-test.foo', '0.1.0-test.1-extra', 'x-test.y', '0.1.0-test.', '0.1.0-test', '0.1.0-test.01',
                  '01.1.0-test.1', '0.1.0-TEST.1', '0.1.0-test.1.2', '-test.1', '0.1-test.1', '', '0.1.0-rc.1',
                  '0.1.0-test.\u0661'):        # the last uses an Arabic-Indic digit, which is not an ASCII digit
            with self.subTest(version=v):
                self.assertFalse(version.is_test(v))
                self.assertIsNone(version.classify(v))

    def test_classify_gives_release_test_or_none(self):
        self.assertEqual(version.classify('0.1.0'), 'release')
        self.assertEqual(version.classify('10.20.30'), 'release')
        self.assertEqual(version.classify('0.1.0-test.7'), 'test')
        self.assertIsNone(version.classify('01.2.3'))
        self.assertIsNone(version.classify(None))
        self.assertIsNone(version.classify(5))

    def test_a_malformed_module_version_is_refused_and_cannot_pass_as_a_release(self):
        # Without this, tightening is_test alone would classify 0.1.0-test.potato as a release and accept mq_mcp.py.
        for v in ('0.1.0-test.potato', '0.1.0-test.1-extra', 'v1'):
            for name in ('mq_mcp.py', 'mq_mcp-' + v + '.py'):
                with self.subTest(version=v, entry=name):
                    ok, msg = version.check_entry('C:/repo/dist/' + name, v)
                    self.assertFalse(ok)
                    self.assertIn('mq_mcp refused to start', msg)
                    self.assertIn(v, msg)

    def test_the_version_value_is_well_formed(self):
        self.assertIsNotNone(version.classify(version.VERSION), version.VERSION)


if __name__ == '__main__':
    unittest.main()

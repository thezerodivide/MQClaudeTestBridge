"""The single authoritative version value for the MCP server, and the startup identity checks.

DL-021 design item 22 (a versioned entry script whose filename version must equal VERSION), design item 27 (the running
interpreter must equal the PYTHON_VERSION captured in the build's own snapshot) and design item 20 (our messages are
printable ASCII by construction). Pure: no file access. check_entry and check_python return (ok, message).
"""
import re

VERSION = '0.1.0-test.1'

PREFIX = 'mq_mcp refused to start: '

# SemVer numeric identifiers: ASCII digits only, no leading zero unless the value is 0. ([0-9], not \d, because \d also
# matches other scripts' digits, and int() would accept them.)
_NUM = r'(?:0|[1-9][0-9]*)'
_RELEASE = re.compile(_NUM + r'\.' + _NUM + r'\.' + _NUM)
_TEST = re.compile(_NUM + r'\.' + _NUM + r'\.' + _NUM + r'-test\.' + _NUM)
_XYZ = re.compile(r'[0-9]+\.[0-9]+\.[0-9]+')


def classify(version):
    """'release' for X.Y.Z, 'test' for X.Y.Z-test.N, None for anything else (a malformed lookalike such as
    0.1.0-test.foo, another pre-release, a leading zero)."""
    if not isinstance(version, str):
        return None
    if _TEST.fullmatch(version):
        return 'test'
    if _RELEASE.fullmatch(version):
        return 'release'
    return None


def is_test(version=VERSION):
    """True only for a well-formed X.Y.Z-test.N version (Protocol section 9)."""
    return classify(version) == 'test'


def _printable(text):
    """External text rendered as printable ASCII: other characters become \\xNN, \\uNNNN or \\UNNNNNNNN escapes."""
    out = []
    for ch in str(text):
        code = ord(ch)
        if 0x20 <= code <= 0x7e:
            out.append(ch)
        elif code <= 0xff:
            out.append('\\x%02x' % code)
        elif code <= 0xffff:
            out.append('\\u%04x' % code)
        else:
            out.append('\\U%08x' % code)
    return ''.join(out)


def check_entry(entry_path, version):
    """The module version must be a well-formed release or test version. A file named mq_mcp-<version>.py must match
    `version`; a plain mq_mcp.py is a release entry and requires that `version` is not a test build."""
    kind = classify(version)
    if kind is None:
        return False, (PREFIX + 'the module version [' + _printable(version)
                       + '] is neither a release version (X.Y.Z) nor a test version (X.Y.Z-test.N).')

    name = re.split(r'[\\/]', str(entry_path))[-1]

    if name == 'mq_mcp.py':
        if kind == 'test':
            return False, (PREFIX + 'the entry file is mq_mcp.py (a release entry) but the modules are test build '
                           + _printable(version) + '; run mq_mcp-' + _printable(version) + '.py.')
        return True, ''

    match = re.fullmatch(r'mq_mcp-(.+)\.py', name)
    if match:
        file_version = match.group(1)
        if file_version == version:
            return True, ''
        return False, (PREFIX + 'the entry file is for version ' + _printable(file_version)
                       + ' but the modules are version ' + _printable(version) + '; use a complete, matching build.')

    return False, PREFIX + 'the entry file name [' + _printable(name) + '] is neither mq_mcp.py nor mq_mcp-<version>.py.'


def check_python(required, version_info):
    """The running interpreter's (major, minor, micro) must equal the required X.Y.Z captured in the build snapshot."""
    text = str(required).strip()
    if not _XYZ.fullmatch(text):
        return False, (PREFIX + 'the captured required Python version [' + _printable(text)
                       + '] is not in the form X.Y.Z.')
    wanted = tuple(int(part) for part in text.split('.'))
    running = tuple(version_info[:3])
    if wanted != running:
        return False, (PREFIX + 'this build requires Python ' + text + ' but is running Python '
                       + '.'.join(str(part) for part in running) + '.')
    return True, ''

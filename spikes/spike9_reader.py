"""Spike 9 (reader): read the test heartbeat file in a tight loop while spike9_writer.lua replaces it.

Every read is classified separately, so a transient sharing/open failure is never counted as a torn heartbeat and
"the text happened to parse as JSON" is never counted as proof of completeness:
  ok                     the bytes read are EXACTLY the bytes the writer publishes for some generation g in 1..N
  missing                the file did not exist at that moment
  open_or_read_failure   the OS refused the open or the read (counted by exception class and error codes)
  invalid_utf8           the bytes were not valid UTF-8
  invalid_json           the text did not parse as JSON (an empty or truncated file lands here)
  inconsistent           valid JSON, but not exactly the bytes of any generation the writer publishes (extra or
                         duplicate keys, wrong field order or whitespace, a wrong "final" flag, a generation outside
                         1..N, or mixed content)
A read is 'ok' only if raw == expected_bytes(g, N), so if the bytes equal a known generation exactly, then by definition
the reader saw one complete published generation. Generations going backwards are counted too.
Standard library only. The file is opened and closed on every read (default sharing, no delete sharing), which is how
a status reader behaves.
Usage: python spike9_reader.py [folder] [N]
  folder  default C:/Users/Public/MacroQuest/Logs/
  N       the number of generations the writer publishes (default 6000; must equal the writer's SPIKE9_N)
"""
import json
import sys
import time

DIR = sys.argv[1] if len(sys.argv) > 1 else 'C:/Users/Public/MacroQuest/Logs/'
if not DIR.endswith('/'):
    DIR += '/'
N = int(sys.argv[2]) if len(sys.argv) > 2 else 6000
HB = DIR + 'spike9_hb.json'
REPORT = DIR + 'spike9_reader_report.txt'
WAIT_FOR_FIRST_S = 240      # how long to wait for the writer to publish the first generation
NO_PROGRESS_S = 30          # stop if no new generation has been seen for this long
MAX_SAMPLES = 3


def expected_bytes(g, n):
    """The exact bytes spike9_writer.lua publishes for generation g (same formulas, same field order, no spaces)."""
    length = 100 + (g * 37) % 400
    letter = chr(97 + g % 26)
    check = (g * 7919 + length) % 1000003
    final = ',"final":true' if g == n else ''
    text = '{"generation":%d,"length":%d,"check":%d%s,"payload":"%s"}' % (g, length, check, final, letter * length)
    return text.encode('ascii')


def classify(raw, n):
    """Return (category, generation_or_None, detail)."""
    try:
        text = raw.decode('utf-8')
    except UnicodeDecodeError as exc:
        return 'invalid_utf8', None, 'UnicodeDecodeError at byte ' + str(exc.start)
    try:
        obj = json.loads(text)
    except ValueError as exc:
        return 'invalid_json', None, 'length ' + str(len(raw)) + ': ' + str(exc)
    if not isinstance(obj, dict):
        return 'inconsistent', None, 'top-level value is not an object'
    g = obj.get('generation')
    if type(g) is not int or not 1 <= g <= n:
        return 'inconsistent', None, 'generation missing, not an integer, or outside 1..' + str(n)
    if raw != expected_bytes(g, n):
        return 'inconsistent', g, 'bytes are not exactly the writer output for generation ' + str(g)
    return 'ok', g, ''


def main():
    counts = {'ok': 0, 'missing': 0, 'open_or_read_failure': 0, 'invalid_utf8': 0, 'invalid_json': 0,
              'inconsistent': 0}
    failure_kinds = {}
    samples = {k: [] for k in counts}
    generations = set()
    last_gen = 0
    regressions = 0
    reads = 0
    saw_final = False

    t_start = time.monotonic()
    while True:                                  # wait for the writer's first publication
        try:
            open(HB, 'rb').close()
            break
        except OSError:
            if time.monotonic() - t_start > WAIT_FOR_FIRST_S:
                print('no heartbeat file appeared within ' + str(WAIT_FOR_FIRST_S) + ' s; nothing measured')
                return 2
            time.sleep(0.01)

    t_read0 = time.monotonic()
    t_progress = t_read0
    while True:
        reads += 1
        try:
            with open(HB, 'rb') as fh:
                raw = fh.read()
        except FileNotFoundError:
            counts['missing'] += 1
            continue
        except OSError as exc:
            counts['open_or_read_failure'] += 1
            key = type(exc).__name__ + ' errno=' + str(exc.errno) + ' winerror=' + str(getattr(exc, 'winerror', None))
            failure_kinds[key] = failure_kinds.get(key, 0) + 1
            continue

        category, g, detail = classify(raw, N)
        counts[category] += 1
        if category != 'ok' and len(samples[category]) < MAX_SAMPLES:
            samples[category].append(detail + ' | first 60 bytes: ' + ascii(raw[:60]))
        if category == 'ok':
            if g < last_gen:
                regressions += 1
            if g > last_gen:
                t_progress = time.monotonic()
            last_gen = max(last_gen, g)
            generations.add(g)
            if g == N:                           # the final generation, established by the exact-bytes match
                saw_final = True
                break
        now = time.monotonic()
        if now - t_progress > NO_PROGRESS_S:
            break

    duration = time.monotonic() - t_read0
    summary = {
        'expected_N': N,
        'reads': reads,
        'duration_s': round(duration, 2),
        'reads_per_s': round(reads / duration) if duration > 0 else None,
        'counts': counts,
        'open_or_read_failure_kinds': failure_kinds,
        'generations_seen': len(generations),
        'highest_generation_seen': last_gen,
        'generation_regressions': regressions,
        'saw_final_generation': saw_final,
        'samples_of_non_ok_reads': samples,
    }
    text = json.dumps(summary, indent=2, ensure_ascii=True)
    with open(REPORT, 'w') as out:
        out.write(text + '\n')
    print(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())

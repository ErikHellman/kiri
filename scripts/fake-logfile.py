#!/usr/bin/env python3
"""Writes one huge fake log file, as fast as the disk and CPU allow.

For testing Kiri's large-file support. The lines come from
scripts/fake-log.py (same formats), but the timestamps are spread evenly
over a past time span instead of following the clock, so a 10 GB file
reads like days of real logging.

    scripts/fake-logfile.py /tmp/huge.log                 # 5 GB of logcat
    scripts/fake-logfile.py /tmp/huge.log --size 20G -f server --span 14d
    scripts/fake-logfile.py /tmp/huge.log --jobs 2        # go easy on the Mac

It overwrites FILE. Several worker processes render chunks in parallel
(default: half the cores) and the main process writes them in order, so
the timestamps keep increasing. The file ends on a whole line, at most one
line short of --size. Stop it with Ctrl-C; what is written stays.
"""

import argparse
import collections
import importlib.util
import multiprocessing
import os
import random
import sys
import time

_spec = importlib.util.spec_from_file_location(
    "fake_log", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake-log.py"))
fake_log = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fake_log)

CHUNK_BYTES = 4 << 20  # rendered per task


def parse_span(text):
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}
    text = text.strip().lower()
    if text[-1:] in units:
        return float(text[:-1]) * units[text[-1]]
    return float(text)


def render(task):
    """Renders `records` log records starting at t0, step seconds apart."""
    fmt, seed, t0, step, records = task
    random.seed(seed)
    make_line = fake_log.FORMATS[fmt]()
    out = []
    t = t0
    for _ in range(records):
        out.extend(make_line(t))
        t += step
    return ("\n".join(out) + "\n").encode()


def main():
    p = argparse.ArgumentParser(description="Write one huge fake log file.",
                                formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog=__doc__.split("\n\n", 1)[1])
    p.add_argument("file", help="file to write (overwritten)")
    p.add_argument("-s", "--size", type=fake_log.parse_size, default=fake_log.parse_size("5G"),
                   metavar="BYTES", help="file size, e.g. 500M, 5G, 20G (default: 5G)")
    p.add_argument("-f", "--format", choices=sorted(fake_log.FORMATS), default="logcat",
                   help="log style (default: logcat)")
    p.add_argument("--span", type=parse_span, default=parse_span("3d"), metavar="TIME",
                   help="time the log covers, ending now, e.g. 6h, 3d, 2w (default: 3d)")
    p.add_argument("-j", "--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2),
                   help="worker processes (default: half the cores)")
    p.add_argument("--seed", type=int, default=1, help="random seed (default: 1; same seed, same lines)")
    args = p.parse_args()

    # Measure the average record size, to spread the time span over the
    # number of records the file will hold.
    sample = render((args.format, args.seed - 1, 0.0, 0.0, 50000))
    per_record = len(sample) / 50000
    total_records = max(1, int(args.size / per_record))
    step = args.span / total_records * 0.99  # the estimate is close; end just before now, not after
    per_chunk = max(1, int(CHUNK_BYTES / per_record))
    t_start = time.time() - args.span

    def task(i):
        return (args.format, args.seed * 1000003 + i, t_start + i * per_chunk * step, step, per_chunk)

    written = 0
    started = time.monotonic()
    last_report = started
    tty = sys.stderr.isatty()
    with open(args.file, "wb") as f, multiprocessing.Pool(args.jobs) as pool:
        # Keep a few chunks in flight per worker, so memory stays bounded
        # when the disk is slower than the workers.
        pending = collections.deque()
        next_chunk = 0
        try:
            while written < args.size:
                while len(pending) < args.jobs * 2:
                    pending.append(pool.apply_async(render, (task(next_chunk),)))
                    next_chunk += 1
                data = pending.popleft().get()
                if written + len(data) >= args.size:
                    data = data[:args.size - written]
                    data = data[:data.rfind(b"\n") + 1]
                    f.write(data)
                    written += len(data)
                    break
                f.write(data)
                written += len(data)
                now = time.monotonic()
                if now - last_report >= 1.0:
                    last_report = now
                    rate = written / max(now - started, 1e-9)
                    eta = (args.size - written) / rate if rate else 0
                    msg = "fake-logfile: %.2f of %.2f GB (%.0f MB/s, %ds left)" % (
                        written / 1e9, args.size / 1e9, rate / 1e6, eta)
                    sys.stderr.write(("\r\033[K" + msg) if tty else msg + "\n")
        except KeyboardInterrupt:
            pass
        finally:
            pool.terminate()
    elapsed = time.monotonic() - started
    if tty:
        sys.stderr.write("\r\033[K")
    sys.stderr.write("fake-logfile: wrote %.2f GB to %s in %.1fs (%.0f MB/s)\n" % (
        written / 1e9, args.file, elapsed, written / 1e6 / max(elapsed, 1e-9)))


if __name__ == "__main__":
    main()

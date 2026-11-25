#!/usr/bin/env python3
"""Writes realistic fake log lines as fast as it can, within a CPU budget.

For testing Kiri's large-file viewer: following a growing file, and
streaming from stdin (`cmd | kiri -`).

    scripts/fake-log.py | kiri -                       # stream into Kiri
    scripts/fake-log.py -o /tmp/app.log                # append to a file, follow it in Kiri
    scripts/fake-log.py -f server --cpu 25 -o /tmp/server.log
    scripts/fake-log.py --rate 200 -f logcat           # a calm 200 lines/s
    scripts/fake-log.py --size 2G -o /tmp/big.log      # write 2 GB, then stop

It runs as one process on one core and sleeps to keep its average CPU use
at --cpu percent of that core (default 50), so the Mac stays responsive
and the reader has room. Writing to a pipe that is full just waits, so a
slow reader slows it down without spending CPU. Stop it with Ctrl-C.

Formats: logcat (Android `logcat -v threadtime`), server (Java/Spring
style app log, with stack traces), nginx (access log), json (one JSON
object per line), syslog (macOS/BSD style). Only the standard library is
used, and Python 3.9 (the one that comes with Xcode) is enough.
"""

import argparse
import os
import random
import signal
import sys
import time

# --- Shared bits ----------------------------------------------------------

WORDS = (
    "cache session user order payment token request response queue worker "
    "config index buffer socket stream channel batch record shard replica "
    "upload download thumbnail profile account invoice cart inventory price "
    "search query result feed message notification device sensor sync job"
).split()

HOSTS = ["api.example.com", "auth.internal", "db-primary:5432", "redis:6379",
         "s3.eu-north-1.amazonaws.com", "cdn.example.net", "10.0.3.17:8080"]

PATHS = ["/api/v1/orders", "/api/v1/orders/{id}", "/api/v1/users/{id}",
         "/api/v1/users/{id}/profile", "/api/v1/cart", "/api/v1/search",
         "/api/v2/feed", "/login", "/logout", "/health", "/metrics",
         "/static/app.{hex}.js", "/static/style.{hex}.css", "/images/{id}.webp",
         "/api/v1/payments/{id}/capture", "/api/v1/inventory/{id}"]

METHODS = ["GET"] * 12 + ["POST"] * 4 + ["PUT", "DELETE", "PATCH", "HEAD"]
STATUSES = [200] * 40 + [201] * 3 + [204] * 3 + [301, 302, 304, 304, 304] + \
    [400, 401, 403, 404, 404, 404, 409, 422, 429] + [500, 502, 503, 504]

USER_AGENTS = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
    "Mozilla/5.0 (X11; Linux x86_64; rv:145.0) Gecko/20100101 Firefox/145.0",
    "okhttp/4.12.0", "curl/8.7.1", "kube-probe/1.31", "Go-http-client/2.0",
    "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
]

EXCEPTIONS = [
    ("java.lang.NullPointerException", "Cannot invoke \"String.length()\" because \"name\" is null"),
    ("java.lang.IllegalStateException", "Expected BEGIN_OBJECT but was STRING at line 1 column 1"),
    ("java.net.SocketTimeoutException", "Read timed out after 30000ms"),
    ("java.io.IOException", "Broken pipe"),
    ("java.util.ConcurrentModificationException", None),
    ("org.postgresql.util.PSQLException", "ERROR: duplicate key value violates unique constraint \"orders_pkey\""),
    ("kotlinx.coroutines.TimeoutCancellationException", "Timed out waiting for 5000 ms"),
]

FRAMES = [
    "com.example.api.OrderController.create(OrderController.kt:{n})",
    "com.example.api.OrderService.place(OrderService.kt:{n})",
    "com.example.data.OrderRepository.save(OrderRepository.kt:{n})",
    "com.example.payments.StripeClient.capture(StripeClient.kt:{n})",
    "org.springframework.web.servlet.FrameworkServlet.service(FrameworkServlet.java:{n})",
    "org.springframework.transaction.support.TransactionTemplate.execute(TransactionTemplate.java:{n})",
    "jdk.internal.reflect.DirectMethodHandleAccessor.invoke(DirectMethodHandleAccessor.java:{n})",
    "java.base/java.lang.reflect.Method.invoke(Method.java:{n})",
    "org.apache.catalina.core.ApplicationFilterChain.doFilter(ApplicationFilterChain.java:{n})",
    "kotlinx.coroutines.DispatchedTask.run(DispatchedTask.kt:{n})",
    "java.base/java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:{n})",
    "java.base/java.lang.Thread.run(Thread.java:{n})",
]

rnd = random.random
randint = random.randint
choice = random.choice
choices = random.choices


def hexid(n=8):
    return "%0*x" % (n, random.getrandbits(n * 4))


def ident():
    return str(randint(1, 999999))


def fill_path(p):
    if "{" in p:
        p = p.replace("{id}", ident()).replace("{hex}", hexid(10))
    return p


def ip():
    if rnd() < 0.6:
        return "10.0.%d.%d" % (randint(0, 9), randint(2, 254))
    return "%d.%d.%d.%d" % (randint(23, 223), randint(0, 255), randint(0, 255), randint(1, 254))


def ms():
    # Mostly fast, with a long tail.
    r = rnd()
    if r < 0.8:
        return randint(1, 40)
    if r < 0.97:
        return randint(40, 800)
    return randint(800, 12000)


def sentence():
    return " ".join(choices(WORDS, k=randint(3, 9)))


def stack_trace(indent="\t"):
    exc, msg = choice(EXCEPTIONS)
    lines = [exc + (": " + msg if msg else "")]
    start = randint(0, 3)
    for frame in FRAMES[start:start + randint(5, 9)]:
        lines.append("%sat %s" % (indent, frame.replace("{n}", str(randint(20, 900)))))
    if rnd() < 0.3:
        lines.append("%s... %d more" % (indent, randint(3, 40)))
    return lines


# --- Timestamps -----------------------------------------------------------
#
# Formatting a time per line is slow, so each format caches the text for
# the current second and only adds milliseconds.

class Clock:
    def __init__(self, fmt):
        self.fmt = fmt
        self.sec = None
        self.text = ""

    def prefix(self, t):
        sec = int(t)
        if sec != self.sec:
            self.sec = sec
            self.text = time.strftime(self.fmt, time.localtime(sec))
        return self.text


# --- Formats --------------------------------------------------------------
#
# Each takes a timestamp (float seconds) and returns a list of lines
# (usually one; more for stack traces).

LOGCAT_LEVELS = "VDIWEF"
LOGCAT_WEIGHTS = [6, 30, 44, 12, 7, 1]

LOGCAT_APPS = [  # (pid, tid range, tags)
    (1432, (1432, 1530), ["ActivityManager", "WindowManager", "PackageManager", "InputDispatcher"]),
    (2871, (2871, 2930), ["OkHttp", "Retrofit", "ExampleApp", "SyncWorker", "RoomDb", "Coil"]),
    (987, (987, 1010), ["SurfaceFlinger", "BufferQueueProducer", "HWComposer"]),
    (3340, (3340, 3370), ["chromium", "cr_media", "WebViewFactory"]),
    (612, (612, 640), ["wificond", "WifiHAL", "ConnectivityService", "NetworkMonitor"]),
    (4120, (4120, 4160), ["GoogleApiManager", "FirebaseMessaging", "GmsCore"]),
]

LOGCAT_MSGS = [
    lambda: "Start proc %d:com.example.app/u0a%d for activity {com.example.app/.MainActivity}" % (randint(3000, 9000), randint(100, 300)),
    lambda: "Displayed com.example.app/.ui.%sActivity: +%dms" % (choice(["Main", "Detail", "Settings", "Checkout"]), randint(120, 1800)),
    lambda: "--> %s https://%s%s" % (choice(METHODS), choice(HOSTS), fill_path(choice(PATHS))),
    lambda: "<-- %d https://%s%s (%dms, %d-byte body)" % (choice(STATUSES), choice(HOSTS), fill_path(choice(PATHS)), ms(), randint(0, 90000)),
    lambda: "Skipped %d frames!  The application may be doing too much work on its main thread." % randint(31, 240),
    lambda: "Background concurrent copying GC freed %d(%dMB) AllocSpace objects, %d(%dMB) LOS objects, %d%% free, %dMB/%dMB, paused %dus total %dms" % (
        randint(10000, 400000), randint(1, 60), randint(0, 40), randint(0, 20), randint(20, 60), randint(20, 200), randint(200, 512), randint(50, 900), randint(10, 400)),
    lambda: "Sync %s finished: %d items in %dms" % (hexid(6), randint(0, 500), ms()),
    lambda: "Loaded image https://cdn.example.net/images/%s.webp into ImageView@%s (%dx%d)" % (ident(), hexid(7), randint(100, 2000), randint(100, 2000)),
    lambda: "Access denied finding property \"ro.vendor.%s\"" % choice(WORDS),
    lambda: "Window{%s u0 com.example.app/com.example.app.MainActivity} %s" % (hexid(7), choice(["focus changed", "drawn", "relayout", "hidden"])),
    lambda: "onStartJob: jobId=%d %s" % (randint(1, 999), sentence()),
    lambda: "Connection pool: %d idle, %d active, evicting %d" % (randint(0, 5), randint(0, 8), randint(0, 3)),
    lambda: sentence(),
]


def make_logcat():
    clock = Clock("%m-%d %H:%M:%S")

    def line(t):
        pid, (tlo, thi), tags = choice(LOGCAT_APPS)
        level = choices(LOGCAT_LEVELS, LOGCAT_WEIGHTS)[0]
        tag = choice(tags)
        head = "%s.%03d %5d %5d %s %s: " % (clock.prefix(t), int(t * 1000) % 1000, pid, randint(tlo, thi), level, tag)
        if level in "EF" and rnd() < 0.35:
            return [head + text for text in stack_trace()]
        return [head + choice(LOGCAT_MSGS)()]
    return line


SERVER_LEVELS = ["TRACE", "DEBUG", "INFO", "WARN", "ERROR"]
SERVER_WEIGHTS = [3, 25, 55, 11, 6]
SERVER_LOGGERS = ["c.e.api.OrderController", "c.e.api.UserController", "c.e.orders.OrderService",
                  "c.e.payments.PaymentService", "c.e.auth.JwtFilter", "o.s.web.servlet.DispatcherServlet",
                  "o.h.engine.jdbc.spi.SqlExceptionHelper", "c.zaxxer.hikari.pool.HikariPool",
                  "o.a.kafka.clients.consumer.KafkaConsumer", "c.e.jobs.ReindexJob"]
SERVER_THREADS = ["http-nio-8080-exec-%d", "scheduling-%d", "kafka-consumer-%d", "ForkJoinPool.commonPool-worker-%d", "main"]

SERVER_MSGS = [
    lambda: "%s %s -> %d (%dms)" % (choice(METHODS), fill_path(choice(PATHS)), choice(STATUSES), ms()),
    lambda: "Order %s placed by user %s: %d items, total %d.%02d EUR" % (hexid(12), ident(), randint(1, 12), randint(5, 900), randint(0, 99)),
    lambda: "Payment %s captured in %dms" % (hexid(16), ms()),
    lambda: "JWT validated for subject=%s scope=[%s]" % (ident(), ", ".join(choices(["read", "write", "orders", "admin", "profile"], k=randint(1, 3)))),
    lambda: "HikariPool-1 - Pool stats (total=%d, active=%d, idle=%d, waiting=%d)" % (20, randint(0, 20), randint(0, 20), randint(0, 5)),
    lambda: "Consumed %d records from orders-events[%d] at offset %d" % (randint(1, 500), randint(0, 11), randint(10000, 99999999)),
    lambda: "Cache %s for key %s:%s" % (choice(["hit", "hit", "hit", "miss", "evict"]), choice(WORDS), ident()),
    lambda: "select o1_0.id,o1_0.status,o1_0.total from orders o1_0 where o1_0.user_id=? and o1_0.created_at>? -- took %dms" % ms(),
    lambda: "Reindexed %d documents in %dms (%d failed)" % (randint(100, 20000), ms(), randint(0, 3)),
    lambda: "Retrying call to https://%s (attempt %d of 3) after %dms" % (choice(HOSTS), randint(1, 3), randint(100, 2000)),
    lambda: "SQL Error: 0, SQLState: %s" % choice(["23505", "40001", "57014", "08006"]),
    lambda: sentence(),
]


def make_server():
    clock = Clock("%Y-%m-%d %H:%M:%S")

    def line(t):
        level = choices(SERVER_LEVELS, SERVER_WEIGHTS)[0]
        thread = choice(SERVER_THREADS)
        if "%d" in thread:
            thread = thread % randint(1, 16)
        head = "%s.%03d %5s %d --- [%15.15s] %-40.40s : " % (
            clock.prefix(t), int(t * 1000) % 1000, level, 48213, thread, choice(SERVER_LOGGERS))
        if level == "ERROR" and rnd() < 0.5:
            trace = stack_trace()
            return [head + "Request processing failed: " + trace[0]] + trace[1:]
        return [head + choice(SERVER_MSGS)()]
    return line


def make_nginx():
    clock = Clock("%d/%b/%Y:%H:%M:%S %z")

    def line(t):
        status = choice(STATUSES)
        return ['%s - - [%s] "%s %s HTTP/%s" %d %d "%s" "%s" %.3f' % (
            ip(), clock.prefix(t), choice(METHODS), fill_path(choice(PATHS)), choice(["1.1", "1.1", "2.0"]),
            status, 0 if status in (204, 304) else randint(120, 250000),
            choice(["-", "-", "https://example.com/", "https://www.google.com/"]),
            choice(USER_AGENTS), ms() / 1000.0)]
    return line


JSON_LEVELS = ["debug", "info", "warn", "error"]
JSON_WEIGHTS = [25, 58, 11, 6]
JSON_SERVICES = ["api-gateway", "orders", "payments", "auth", "search", "notifier"]


def make_json():
    clock = Clock("%Y-%m-%dT%H:%M:%S")

    def line(t):
        level = choices(JSON_LEVELS, JSON_WEIGHTS)[0]
        status = choice(STATUSES)
        return ['{"ts":"%s.%03dZ","level":"%s","service":"%s","trace_id":"%s","span_id":"%s","msg":"%s",'
                '"http":{"method":"%s","path":"%s","status":%d,"duration_ms":%d},"user_id":%s}' % (
                    clock.prefix(t), int(t * 1000) % 1000, level, choice(JSON_SERVICES), hexid(32), hexid(16),
                    sentence(), choice(METHODS), fill_path(choice(PATHS)), status, ms(),
                    ident() if rnd() < 0.7 else "null")]
    return line


SYSLOG_PROCS = ["kernel", "launchd", "mDNSResponder", "WindowServer", "sharingd", "bluetoothd",
                "symptomsd", "trustd", "cloudd", "Spotlight", "powerd", "airportd"]
SYSLOG_MSGS = [
    lambda: "Registering for notification %s.%s" % (choice(["com.apple", "se.hellsoft"]), choice(WORDS)),
    lambda: "Service exited with abnormal code: %d" % randint(1, 255),
    lambda: "en0: link quality changed to %d%%" % randint(10, 100),
    lambda: "Sleep assertion %s released after %ds" % (hexid(8), randint(1, 3600)),
    lambda: "Received %d bytes from %s" % (randint(40, 65000), ip()),
    lambda: sentence(),
]


def make_syslog():
    clock = Clock("%b %d %H:%M:%S")

    def line(t):
        return ["%s macbook %s[%d]: %s" % (clock.prefix(t), choice(SYSLOG_PROCS), randint(80, 9000), choice(SYSLOG_MSGS)())]
    return line


FORMATS = {"logcat": make_logcat, "server": make_server, "nginx": make_nginx,
           "json": make_json, "syslog": make_syslog}


# --- Writing --------------------------------------------------------------

def parse_size(text):
    text = text.strip().upper().rstrip("B")
    mult = 1
    for suffix, m in (("K", 1 << 10), ("M", 1 << 20), ("G", 1 << 30), ("T", 1 << 40)):
        if text.endswith(suffix):
            text, mult = text[:-1], m
            break
    return int(float(text) * mult)


def main():
    p = argparse.ArgumentParser(description="Write realistic fake log lines, fast but within a CPU budget.",
                                formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 1)[1])
    p.add_argument("-f", "--format", choices=sorted(FORMATS), default="logcat", help="log style (default: logcat)")
    p.add_argument("-o", "--output", metavar="FILE", help="append to FILE instead of writing to stdout")
    p.add_argument("--truncate", action="store_true", help="empty FILE first instead of appending")
    p.add_argument("--cpu", type=float, default=50, metavar="PCT",
                   help="average CPU use, in percent of one core (default: 50; 100 = no limit)")
    p.add_argument("--rate", type=float, metavar="N", help="at most N lines per second")
    p.add_argument("--lines", type=int, metavar="N", help="stop after N lines")
    p.add_argument("--size", type=parse_size, metavar="BYTES", help="stop after this many bytes (e.g. 500M, 2G)")
    p.add_argument("--duration", type=float, metavar="SEC", help="stop after SEC seconds")
    p.add_argument("--seed", type=int, help="random seed, for repeatable output")
    p.add_argument("-q", "--quiet", action="store_true", help="no summary on stderr at the end")
    args = p.parse_args()

    if args.seed is not None:
        random.seed(args.seed)
    cpu_share = max(1.0, min(args.cpu, 100.0)) / 100.0
    make_line = FORMATS[args.format]()

    if args.output:
        mode = os.O_WRONLY | os.O_CREAT | (os.O_TRUNC if args.truncate else os.O_APPEND)
        fd = os.open(args.output, mode, 0o644)
    else:
        fd = sys.stdout.fileno()
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)  # reader went away: just stop

    start_wall = time.monotonic()
    start_cpu = time.process_time()
    last_t = time.time()
    lines_out = 0
    bytes_out = 0
    batch = 256  # lines per write; tuned so a batch takes about 10 ms

    try:
        while True:
            n = batch
            if args.lines is not None:
                n = min(n, args.lines - lines_out)
                if n <= 0:
                    break
            if args.rate:
                n = max(1, min(n, int(args.rate / 20)))

            # Spread this batch's timestamps over the time since the last one,
            # so they are real, increasing, and evenly spaced.
            now = time.time()
            step = max(now - last_t, 0.0) / n
            t = last_t
            out = []
            for _ in range(n):
                t += step
                out.extend(make_line(t))
            last_t = now
            if args.lines is not None:
                del out[args.lines - lines_out:]
            data = ("\n".join(out) + "\n").encode()

            full = args.size is not None and bytes_out + len(data) >= args.size
            if full:  # stop at the last whole line that fits
                data = data[:args.size - bytes_out]
                data = data[:data.rfind(b"\n") + 1]
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            lines_out += data.count(b"\n") if full else len(out)
            bytes_out += len(data)

            wall = time.monotonic() - start_wall
            if full:
                break
            if args.duration is not None and wall >= args.duration:
                break

            # Sleep long enough to keep average CPU use at the budget and
            # the line count under --rate.
            cpu = time.process_time() - start_cpu
            wait = cpu / cpu_share - wall if cpu_share < 1 else 0.0
            if args.rate:
                wait = max(wait, lines_out / args.rate - wall)
            if wait > 0:
                time.sleep(min(wait, 1.0))

            # Aim for ~10 ms of work per batch: bigger writes are cheaper, but
            # smaller ones keep the output smooth for a reader following it.
            if lines_out > batch and cpu > 0:
                per_line = cpu / lines_out
                batch = int(min(max(0.010 / per_line, 16), 20000))
    finally:
        if args.output:
            os.close(fd)
        if not args.quiet:
            wall = max(time.monotonic() - start_wall, 1e-9)
            cpu = time.process_time() - start_cpu
            sys.stderr.write("fake-log: %d lines, %.1f MB in %.1fs (%.0f lines/s, %.1f MB/s, %.0f%% CPU)\n" % (
                lines_out, bytes_out / 1e6, wall, lines_out / wall, bytes_out / 1e6 / wall, 100 * cpu / wall))


if __name__ == "__main__":
    main()

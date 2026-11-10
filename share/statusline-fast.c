/* statusline-fast: the away and rest replays of bin/statusline.sh's first pass (docs/statusline-contract.md
 * "Away replay", "Rest replay") without a bash start. Built by bin/statusline-fast-build; never edited apart from
 * that first pass: tests/test_statusline_hooks.sh (section fast-parity) feeds both the same fixtures.
 *
 * Sound, not complete. It prints a stored render only where the script's first pass would print the same bytes,
 * and writes the same timing row. Anything else — no replay, a stale build, or any input whose reading by bash it
 * does not reproduce to the byte (NUL, invalid UTF-8, odd numbers) — execs the script with the same stdin bytes
 * and an untouched environment, and the script decides again. So the script stays the single source of the full
 * render, of the replay records, and of every rule this file only repeats.
 *
 * Stale: SL_FP is a hash of the rule sources (the script's first pass, share/presence.sh, share/cpu-ms.sh, this
 * file) taken at build time; a build whose sources have moved since never replays.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#if !defined(SL_ROOT) || !defined(SL_FP) || !defined(SL_AWAY_FRESH_S)
#error "build with bin/statusline-fast-build: SL_ROOT, SL_FP and SL_AWAY_FRESH_S come from it"
#endif

/* The suite builds a second copy that hands off to a stub, to see which renders this program takes itself. */
#ifndef SL_SCRIPT
#define SL_SCRIPT SL_ROOT "/bin/statusline.sh"
#endif
#define SCRIPT SL_ROOT "/bin/statusline.sh"
/* The script reads its payload with `read -N 16777216`. */
#define PAYLOAD_MAX 16777216
#define FILE_MAX (64u << 20)
/* The last lines of the script's first pass: the hash covers the file up to here. */
#define PASS_END "\n. \"$statusline_self\"\nexit\nfi\n}\n"

typedef struct {
  char *p;
  size_t n;
} buf;

static struct timeval started;
/* Set wherever bash might read an input differently from the bytes compared here: the script decides. */
static int unsure;

static void grow(buf *b, size_t *cap, size_t want) {
  if (want <= *cap) return;
  while (*cap < want) *cap = *cap ? *cap * 2 : 16384;
  b->p = realloc(b->p, *cap);
  if (!b->p) _exit(111);
}

/* A whole fd, at most max bytes: 0 read to its end, -1 a read error (what was read stays), -2 longer than max. */
static int slurp_fd(int fd, buf *b, size_t max) {
  size_t cap = 0;
  b->p = NULL, b->n = 0;
  for (;;) {
    grow(b, &cap, b->n + 16384);
    ssize_t got = read(fd, b->p + b->n, cap - b->n);
    if (got < 0 && errno == EINTR) continue;
    if (got < 0) return -1;
    if (got == 0) return 0;
    b->n += (size_t)got;
    if (b->n > max) return -2;
  }
}

/* As `read -r -d '' var <path` leaves var: the bytes of the file, empty when it cannot be opened or read. A NUL
 * (bash stops there) or a file past max makes it unsure. */
static void slurp(const char *path, buf *b, size_t max) {
  int fd = open(path, O_RDONLY);
  b->p = NULL, b->n = 0;
  if (fd < 0) return;
  if (slurp_fd(fd, b, max) == -2) unsure = 1;
  close(fd);
  if (b->n && memchr(b->p, 0, b->n)) unsure = 1;
}

/* Strict UTF-8 with no NUL, \x01 or \x7f (bash's own quoting bytes inside `read`): bytes bash carries unchanged
 * in a C locale and in a UTF-8 one. */
static int plain_text(const char *s, size_t n) {
  const unsigned char *p = (const unsigned char *)s, *end = p + n;
  while (p < end) {
    unsigned c = *p;
    if (c == 0 || c == 1 || c == 0x7f) return 0;
    if (c < 0x80) { p++; continue; }
    int more;
    unsigned min;
    if (c >= 0xc2 && c <= 0xdf) more = 1, min = 0x80, c &= 0x1f;
    else if (c >= 0xe0 && c <= 0xef) more = 2, min = 0x800, c &= 0x0f;
    else if (c >= 0xf0 && c <= 0xf4) more = 3, min = 0x10000, c &= 0x07;
    else return 0;
    if (end - p <= more) return 0;
    for (int i = 1; i <= more; i++) {
      if ((p[i] & 0xc0) != 0x80) return 0;
      c = (c << 6) | (p[i] & 0x3f);
    }
    if (c < min || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) return 0;
    p += more + 1;
  }
  return 1;
}

static uint64_t fnv(uint64_t h, const char *p, size_t n) {
  for (size_t i = 0; i < n; i++) h = (h ^ (unsigned char)p[i]) * 1099511628211ull;
  return h;
}

/* The hash of the rule sources as they are now; 0 when one is missing or the first pass has no end. */
static uint64_t fingerprint(void) {
  static const char *const whole[] = {SL_ROOT "/share/presence.sh", SL_ROOT "/share/cpu-ms.sh",
                                      SL_ROOT "/share/statusline-fast.c"};
  uint64_t h = 1469598103934665603ull;
  buf b;
  for (size_t i = 0; i < sizeof whole / sizeof *whole; i++) {
    int fd = open(whole[i], O_RDONLY);
    if (fd < 0) return 0;
    int rc = slurp_fd(fd, &b, FILE_MAX);
    close(fd);
    if (rc) return 0;
    h = fnv(fnv(h, b.p, b.n), "\xff", 1);
    free(b.p);
  }
  int fd = open(SCRIPT, O_RDONLY);
  if (fd < 0) return 0;
  static char head[65536];
  ssize_t got = read(fd, head, sizeof head);
  close(fd);
  if (got <= 0) return 0;
  char *end = memmem(head, (size_t)got, PASS_END, sizeof PASS_END - 1);
  if (!end) return 0;
  h = fnv(h, head, (size_t)(end - head) + sizeof PASS_END - 1);
  return h ? h : 1;
}

/* The script, with the bytes already read as its stdin: a pipe, filled here when it takes them whole, by a child
 * for the part that does not fit. The exec keeps this pid, so the script's $PPID is the parent seen here. */
static void hand_off(const buf *in, char **argv) {
  int fds[2];
  if (pipe(fds) == 0) {
    size_t done = 0;
    fcntl(fds[1], F_SETFL, O_NONBLOCK);
    while (done < in->n) {
      ssize_t put = write(fds[1], in->p + done, in->n - done);
      if (put < 0 && errno == EINTR) continue;
      if (put <= 0) break;
      done += (size_t)put;
    }
    if (done < in->n) {
      pid_t child = fork();
      if (child == 0) {
        close(fds[0]);
        fcntl(fds[1], F_SETFL, 0);
        while (done < in->n) {
          ssize_t put = write(fds[1], in->p + done, in->n - done);
          if (put < 0 && errno == EINTR) continue;
          if (put <= 0) break;
          done += (size_t)put;
        }
        _exit(0);
      }
    }
    close(fds[1]);
    dup2(fds[0], 0);
    close(fds[0]);
  }
  argv[0] = (char *)SL_SCRIPT;
  execv(SL_SCRIPT, argv);
  dprintf(2, "statusline-fast: cannot run %s: %s\n", SL_SCRIPT, strerror(errno));
  _exit(127);
}

static int is_space(unsigned char c) { return c == ' ' || (c >= 9 && c <= 13); }

static const char *spaces(const char *p, const char *end) {
  while (p < end && is_space((unsigned char)*p)) p++;
  /* A UTF-8 locale's [[:space:]] also takes spaces outside ASCII. */
  if (p < end && (unsigned char)*p >= 0x80) unsure = 1;
  return p;
}

/* `"<name>"[[:space:]]*:[[:space:]]*` then `"([^"<stop>]+)"` (quoted) or `[0-9]+`: the leftmost match, as =~
 * finds it. from..to is the whole match, val..vend the group (the digits). */
static int field(const buf *in, const char *name, int quoted, char stop, const char **from, const char **to,
                 const char **val, const char **vend) {
  const char *p = in->p, *end = in->p + in->n;
  size_t len = strlen(name);
  while ((p = memmem(p, (size_t)(end - p), name, len))) {
    const char *q = spaces(p + len, end);
    if (q < end && *q == ':') {
      q = spaces(q + 1, end);
      const char *v = q;
      if (quoted) {
        if (q < end && *q == '"') {
          v = ++q;
          while (q < end && *q != '"' && !(stop && *q == stop)) q++;
          if (q > v && q < end && *q == '"') {
            *from = p, *val = v, *vend = q, *to = q + 1;
            return 1;
          }
        }
      } else {
        while (q < end && *q >= '0' && *q <= '9') q++;
        if (q > v) {
          *from = p, *val = v, *vend = q, *to = q;
          return 1;
        }
      }
    }
    p++;
  }
  return 0;
}

/* Digits only, at most 18: a number bash's `[ -lt ]` and $(( )) read the same way. A leading zero is octal to
 * $(( )), so `arith` refuses it. */
static int number(const char *s, size_t n, int arith, long long *out) {
  if (n == 0 || n > 18 || (arith && n > 1 && s[0] == '0')) return 0;
  long long v = 0;
  for (size_t i = 0; i < n; i++) {
    if (s[i] < '0' || s[i] > '9') return 0;
    v = v * 10 + (s[i] - '0');
  }
  *out = v;
  return 1;
}

static const char *env_or(const char *name, const char *fallback) {
  const char *v = getenv(name);
  return v && *v ? v : fallback;
}

static char *path3(const char *a, const char *b, const char *c) {
  size_t la = strlen(a), lb = strlen(b), lc = strlen(c);
  char *p = malloc(la + lb + lc + 1);
  if (!p) _exit(111);
  memcpy(p, a, la), memcpy(p + la, b, lb), memcpy(p + la + lb, c, lc + 1);
  return p;
}

/* `${VAR:-$HOME<tail>}`; bash fills an unset HOME from the password file, so without one the script decides. */
static const char *dir_or_home(const char *name, const char *tail) {
  const char *v = getenv(name);
  if (v && *v) return v;
  const char *home = getenv("HOME");
  if (!home) { unsure = 1; return ""; }
  return path3(home, tail, "");
}

/* bash's `a -nt b`: a exists and b does not, or a's mtime is the later one, to the nanosecond. */
static int newer(const char *a, const char *b) {
  struct stat sa, sb;
  /* bash answers /dev/fd/N from the descriptor. */
  if (!strncmp(a, "/dev/", 5) || !strncmp(b, "/dev/", 5)) { unsure = 1; return 1; }
  if (stat(a, &sa) != 0) return 0;
  if (stat(b, &sb) != 0) return 1;
  return sa.st_mtimespec.tv_sec != sb.st_mtimespec.tv_sec ? sa.st_mtimespec.tv_sec > sb.st_mtimespec.tv_sec
                                                          : sa.st_mtimespec.tv_nsec > sb.st_mtimespec.tv_nsec;
}

/* share/presence.sh presence_away: the mark is `<digits>\t<digits>\n` and was written within SL_AWAY_FRESH_S.
 * A line of another shape that bash's `read` could still split into two numbers is left to the script. */
static int away(long long now) {
  char line[256];
  char *mark = path3(dir_or_home("SPEED_DOCTOR_DIR", "/.cache/speed-doctor"), "/presence/away", "");
  if (unsure) return 0;
  int fd = open(mark, O_RDONLY);
  if (fd < 0) return 0;
  ssize_t got = read(fd, line, sizeof line);
  close(fd);
  if (got <= 0) return 0;
  char *nl = memchr(line, '\n', (size_t)got), *tab = memchr(line, '\t', (size_t)got);
  long long left, written;
  if (!nl) {
    /* No newline before the end of the file: `read` fails and the mark reads as present. */
    if ((size_t)got == sizeof line || memchr(line, 0, (size_t)got)) unsure = 1;
    return 0;
  }
  if (!tab || tab > nl || !number(line, (size_t)(tab - line), 0, &left) ||
      !number(tab + 1, (size_t)(nl - tab - 1), 1, &written)) {
    unsure = 1;
    return 0;
  }
  return now - written <= SL_AWAY_FRESH_S;
}

static void put(int fd, const char *p, size_t n) {
  while (n) {
    ssize_t did = write(fd, p, n);
    if (did < 0 && errno == EINTR) continue;
    if (did <= 0) return;
    p += did, n -= (size_t)did;
  }
}

/* One field of bash `times`, in ms: bash rounds each to the millisecond before share/cpu-ms.sh adds them. */
static long ms(struct timeval t) { return t.tv_sec * 1000 + (t.tv_usec + 500) / 1000; }

/* statusline_timing_row: start, end (epoch microseconds), the session, CPU ms of this process and its children,
 * the kind — one O_APPEND write, the directory made on a first failure, a failed write silent. */
static void timing_row(const char *base, const char *sid, size_t sid_n, char kind) {
  struct timeval end;
  struct rusage self, kids;
  struct tm tm;
  char day[16], row[512];
  gettimeofday(&end, NULL);
  getrusage(RUSAGE_SELF, &self), getrusage(RUSAGE_CHILDREN, &kids);
  long cpu = ms(self.ru_utime) + ms(self.ru_stime) + ms(kids.ru_utime) + ms(kids.ru_stime);
  time_t now = end.tv_sec;
  localtime_r(&now, &tm);
  strftime(day, sizeof day, "%Y-%m-%d", &tm);
  char *dir = path3(base, "/statusline", ""), *file = path3(dir, "/", path3(day, ".tsv", ""));
  int n = snprintf(row, sizeof row, "%lld%06d\t%lld%06d\t%.*s\t%ld\t%c\n", (long long)started.tv_sec,
                   (int)started.tv_usec, (long long)end.tv_sec, (int)end.tv_usec, (int)sid_n, sid, cpu, kind);
  int fd = open(file, O_WRONLY | O_APPEND | O_CREAT, 0666);
  if (fd < 0) {
    /* mkdir -p */
    for (char *slash = dir + 1;; slash++) {
      if (*slash != '/' && *slash != 0) continue;
      char keep = *slash;
      *slash = 0;
      mkdir(dir, 0777);
      *slash = keep;
      if (!keep) break;
    }
    fd = open(file, O_WRONLY | O_APPEND | O_CREAT, 0666);
  }
  if (fd >= 0) put(fd, row, (size_t)n);
}

/* Returns when this render is not a replay this program can stand behind. */
static void replay(const buf *in) {
  const char *from, *to, *sid, *sid_end, *tp, *tp_end;
  if (in->n >= PAYLOAD_MAX || !plain_text(in->p, in->n)) return;
  if (!field(in, "\"session_id\"", 1, '/', &from, &to, &sid, &sid_end) || unsure) return;
  size_t sid_n = (size_t)(sid_end - sid);
  /* The row is one write of a fixed buffer. */
  if (sid_n > 256) return;
  int has_tp = field(in, "\"transcript_path\"", 1, 0, &from, &to, &tp, &tp_end);
  if (unsure) return;
  char *session = strndup(sid, sid_n);
  const char *cache = dir_or_home("STATUSLINE_CACHE_DIR", "/.cache/claude-statusline");
  const char *journal = dir_or_home("HARNESS_DOCTOR_DIR", "/.cache/harness-doctor");
  if (unsure) return;
  long long now = (long long)started.tv_sec;
  buf out;

  if (away(now) && !unsure && has_tp) {
    char *transcript = strndup(tp, (size_t)(tp_end - tp)), *render = path3(cache, "/render-", session);
    struct stat st;
    if (stat(render, &st) == 0 && st.st_size > 0 && !newer(transcript, render) && !unsure) {
      slurp(render, &out, FILE_MAX);
      if (!unsure && out.n && plain_text(out.p, out.n)) {
        put(1, out.p, out.n);
        timing_row(journal, sid, sid_n, 'a');
        exit(0);
      }
      if (out.n) return;
    }
  }
  if (unsure) return;

  const char *rest_s = getenv("STATUSLINE_REST_S");
  if (rest_s && !strcmp(rest_s, "0")) return;
  char *record = path3(cache, "/render-rest-", session), *stamp = path3(record, ".at", "");
  buf rec;
  slurp(record, &rec, FILE_MAX);
  /* Fields \x1e-separated: rest1, good-until epoch, the env key, the payload key, the lines, a field per file
   * read, end. */
  if (unsure || rec.n < 4 || memcmp(rec.p + rec.n - 4, "\x1e" "end", 4) || !plain_text(rec.p, rec.n)) return;
  const char *f[5], *p = rec.p, *end = rec.p + rec.n - 4;
  size_t fn[5];
  for (int i = 0; i < 5; i++) {
    const char *sep = memchr(p, 0x1e, (size_t)(end - p));
    if (!sep && i < 4) return;
    f[i] = p, fn[i] = (size_t)((sep ? sep : end) - p);
    p = sep ? sep + 1 : end;
    if (i == 4 && !sep) p = NULL;
  }
  if (fn[0] != 5 || memcmp(f[0], "rest1", 5)) return;
  long long until;
  const char *fixed = getenv("STATUSLINE_NOW");
  if (fixed && *fixed && !number(fixed, strlen(fixed), 0, &now)) return;
  if (!number(f[1], fn[1], 0, &until) || now >= until) return;

  /* COLUMNS, the parent, the fit margin and the account variables, each closed by \x1f. */
  char key[4096];
  int key_n = snprintf(key, sizeof key, "%s\x1f%d\x1f%s\x1f%s\x1f%s\x1f%s\x1f", env_or("COLUMNS", ""), (int)getppid(),
                       env_or("STATUSLINE_FIT_MARGIN", ""), env_or("CLAUDE_LIMITS_ACCOUNT", ""),
                       env_or("CLAUDE_CONFIG_DIR", ""), env_or("CLAUDEGPT_ACCOUNT", ""));
  if (key_n < 0 || (size_t)key_n >= sizeof key || fn[2] != (size_t)key_n || memcmp(f[2], key, fn[2])) return;

  /* The payload but for the first `"total_duration_ms": <digits>`. */
  const char *dv, *dv_end;
  size_t cut = 0, head = in->n;
  if (field(in, "\"total_duration_ms\"", 0, 0, &from, &to, &dv, &dv_end)) cut = (size_t)(to - from), head = (size_t)(from - in->p);
  if (unsure || fn[3] != in->n - cut || memcmp(f[3], in->p, head) ||
      memcmp(f[3] + head, in->p + head + cut, in->n - head - cut))
    return;

  while (p) {
    const char *sep = memchr(p, 0x1e, (size_t)(end - p));
    size_t n = (size_t)((sep ? sep : end) - p);
    if (n == 0) return;
    if (*p == 'm') {
      /* A file the render read, written since the stamp it took as it began. */
      if (newer(strndup(p + 1, n - 1), stamp) || unsure) return;
    } else if (*p == 'c') {
      /* c<path>\x1d<bytes>: the bytes the render read; with no \x1d bash compares the whole field. */
      const char *gs = memchr(p, 0x1d, n);
      const char *want = gs ? gs + 1 : p;
      size_t want_n = gs ? n - (size_t)(gs + 1 - p) : n;
      buf got;
      slurp(strndup(p + 1, (gs ? (size_t)(gs - p) : n) - 1), &got, FILE_MAX);
      if (unsure || got.n != want_n || memcmp(got.p, want, want_n)) return;
    } else {
      return;
    }
    p = sep ? sep + 1 : NULL;
  }
  put(1, f[4], fn[4]);
  timing_row(journal, sid, sid_n, 'r');
  exit(0);
}

int main(int argc, char **argv) {
  gettimeofday(&started, NULL);
  if (argc == 2 && !strcmp(argv[1], "--fingerprint")) {
    /* `<built> <now>`, status 0 while they agree (the build and the doctor read it). */
    uint64_t now = fingerprint();
    printf("%016llx %016llx\n", (unsigned long long)SL_FP, (unsigned long long)now);
    return now && now == SL_FP ? 0 : 1;
  }
  buf in;
  slurp_fd(0, &in, (size_t)-1 >> 1);
  if (fingerprint() == SL_FP) replay(&in);
  hand_off(&in, argv);
}

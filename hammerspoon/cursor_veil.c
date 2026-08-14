#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define VEIL_FAILSAFE_MS 3000

typedef int CGSConnectionID;
extern CGSConnectionID _CGSDefaultConnection(void);
extern CGError CGSSetConnectionProperty(CGSConnectionID cid, CGSConnectionID targetCid,
                                        CFStringRef key, CFTypeRef value);

static volatile sig_atomic_t stopping;
static int hidden;
static int waitingForMouse;
static int propertyClaimed;
static int64_t showDeadline;

extern Boolean NSApplicationLoad(void);
extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *context);

static int64_t monotonicMilliseconds(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return 0;
  }
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void setHiddenUntilMouseMoves(BOOL value) {
  void *pool = objc_autoreleasePoolPush();
  NSApplicationLoad();
  Class cursor = objc_getClass("NSCursor");
  SEL selector = sel_registerName("setHiddenUntilMouseMoves:");
  ((void (*)(id, SEL, BOOL))objc_msgSend)((id)cursor, selector, value);
  waitingForMouse = value == YES;
  objc_autoreleasePoolPop(pool);
}

static void balanceCursor(void) {
  showDeadline = 0;
  if (!hidden) {
    return;
  }
  CGDisplayShowCursor(kCGDirectMainDisplay);
  hidden = 0;
}

static void forceShowCursor(void) {
  if (waitingForMouse) {
    setHiddenUntilMouseMoves(NO);
  }
  balanceCursor();
}

static void settleCursor(void) {
  balanceCursor();
  setHiddenUntilMouseMoves(YES);
}

static void hideCursor(void) {
  if (!propertyClaimed) {
    CGSConnectionID cid = _CGSDefaultConnection();
    CGSSetConnectionProperty(cid, cid, CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
    propertyClaimed = 1;
  }
  if (!hidden && CGDisplayHideCursor(kCGDirectMainDisplay) == kCGErrorSuccess) {
    hidden = 1;
  }
  showDeadline = monotonicMilliseconds() + VEIL_FAILSAFE_MS;
}

static void requestStop(int signalNumber) {
  (void)signalNumber;
  stopping = 1;
}

static int installHandler(int signalNumber) {
  struct sigaction action;
  memset(&action, 0, sizeof action);
  action.sa_handler = requestStop;
  sigemptyset(&action.sa_mask);
  return sigaction(signalNumber, &action, NULL);
}

static void handleLine(char *line) {
  if (strcmp(line, "hide") == 0) {
    hideCursor();
  } else if (strcmp(line, "settle") == 0) {
    settleCursor();
  } else if (strcmp(line, "show") == 0) {
    forceShowCursor();
  }
}

int main(void) {
  atexit(forceShowCursor);
  if (installHandler(SIGTERM) != 0 || installHandler(SIGINT) != 0
      || installHandler(SIGHUP) != 0) {
    return 1;
  }

  char input[256];
  size_t used = 0;
  while (!stopping) {
    int timeout = -1;
    if (showDeadline != 0) {
      int64_t remaining = showDeadline - monotonicMilliseconds();
      timeout = remaining > 0 ? (remaining > INT32_MAX ? INT32_MAX : (int)remaining) : 0;
    }

    struct pollfd descriptor = { .fd = STDIN_FILENO, .events = POLLIN | POLLHUP };
    int ready = poll(&descriptor, 1, timeout);
    if (stopping) {
      break;
    }
    if (ready < 0) {
      if (errno == EINTR) {
        continue;
      }
      break;
    }
    if (ready == 0) {
      forceShowCursor();
      continue;
    }

    char chunk[128];
    ssize_t count = read(STDIN_FILENO, chunk, sizeof chunk);
    if (count <= 0) {
      if (count < 0 && errno == EINTR) {
        continue;
      }
      break;
    }
    for (ssize_t index = 0; index < count; index++) {
      char byte = chunk[index];
      if (byte == '\n' || byte == '\r') {
        input[used] = '\0';
        handleLine(input);
        used = 0;
      } else if (used + 1 < sizeof input) {
        input[used++] = byte;
      } else {
        used = 0;
      }
    }
  }

  forceShowCursor();
  return 0;
}

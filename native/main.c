#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <math.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifdef HAVE_EI
#include <libei.h>
#endif

#include <sys/time.h>
#include <time.h>

#ifdef HAVE_UINPUT
#include <fcntl.h>
#include <linux/uinput.h>
#endif

#ifdef HAVE_X11
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <X11/keysym.h>
#endif

/*
 * Line protocol over stdin/stdout.
 *
 * Input:
 *   m  <dx> <dy>      relative pointer motion (floats)
 *   b  <btn> <0|1>    button press/release (1=L 2=M 3=R 4=side 5=extra)
 *   c  <btn>          click (press+release in one command)
 *   s  <dx> <dy>      smooth scroll delta (floats, in pixels)
 *   d  <dx> <dy>      discrete scroll delta (ints, in notches)
 *   q                 end current scroll gesture
 *   k  <key> <0|1>    keyboard key (1=Ctrl 2=Shift 3=Alt 4=Super, else evdev code)
 *   ping -> pong
 *   quit
 *
 * Output:
 *   state connecting
 *   state ready backend=<ei|uinput|x11>
 *   state lost <reason>
 *   err <message>
 *   pong
 *
 * Backend order: libei (portal on GNOME/KDE) -> uinput (/dev/uinput,
 * compositors without the libei portal, e.g. Hyprland) -> XTest (X11 only).
 * Override with TOUCHPAD_BACKEND=ei|uinput|x11.
 */

typedef enum { MODE_NONE, MODE_EI, MODE_UINPUT, MODE_X11 } Mode;

static struct {
    Mode mode;

    struct ei *ei;
    struct ei_device *device;
    bool ei_active;

    Display *dpy;
    bool x11_xtest;
    double x11_ax, x11_ay; /* motion accumulator for subpixel accuracy */
    double x11_sx, x11_sy; /* scroll accumulator */
} B;

static char inbuf[4096];
static size_t inlen = 0;
static int in_fd = STDIN_FILENO;
static int out_fd = STDOUT_FILENO;
static int listen_fd = -1;

/* Input state trackers: whatever the client pressed must be released when
 * that client goes away, otherwise the button/key stays stuck (which on each
 * subsequent client makes input appear broken, and on Wayland seats can also
 * swallow clicks of other pointer devices). */
static uint32_t held_btns = 0; /* bit (btn-1) for protocol buttons 1..5 */
static int held_keys[64];
static int nheld_keys = 0;

#ifdef HAVE_X11
static KeySym x11_keysym(int key);
#endif

static void
vwrite_line(int fd, const char *fmt, va_list ap)
{
    char buf[1024];
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    if (n < 0)
        return;
    if ((size_t)n > sizeof buf - 1)
        n = (int)(sizeof buf - 1);
    (void)write(fd, buf, (size_t)n);
    (void)write(fd, "\n", 1);
}

static void
reply(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vwrite_line(out_fd, fmt, ap);
    va_end(ap);
}

static void
dlog(const char *fmt, ...)
{
    char buf[1024];
    va_list ap;
    struct timeval tv;
    struct tm tm;
    char t[32];
    gettimeofday(&tv, NULL);
    localtime_r(&tv.tv_sec, &tm);
    strftime(t, sizeof t, "%H:%M:%S", &tm);
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "%s.%03ld %s\n", t, (long)tv.tv_usec / 1000, buf);
}

/* ------------------------------------------------------------------ input */

static void handle_line(char *line);

static bool
read_stdin(void)
{
    char tmp[1024];
    ssize_t r = read(in_fd, tmp, sizeof tmp);
    if (r == 0)
        return false; /* EOF */
    if (r < 0) {
        if (errno == EINTR)
            return true;
        return false;
    }
    for (ssize_t i = 0; i < r; i++) {
        if (tmp[i] == '\n') {
            if (inlen > 0) {
                inbuf[inlen] = '\0';
                handle_line(inbuf);
            }
            inlen = 0;
        } else if (inlen + 1 < sizeof inbuf) {
            inbuf[inlen++] = tmp[i];
        } else {
            inlen = 0; /* drop overlong line */
        }
    }
    dlog("read: %d bytes [%s]", (int)r,
         tmp[r - 1] == '\n' ? "newline-terminated" : "NO trailing newline");
    if (r > 0) {
        char hx[2048];
        size_t off = 0;
        for (ssize_t i = 0; i < r && off + 4 < sizeof hx; i++)
            off += (size_t)snprintf(hx + off, sizeof hx - off, "%02x ",
                                    (unsigned char)tmp[i]);
        hx[off] = '\0';
        dlog("read-hex: %s", hx);
    }
    return true;
}

/* ------------------------------------------------------------------- ei */

#ifdef HAVE_EI

static void
ei_drain(void)
{
    struct ei_event *ev;
    while ((ev = ei_get_event(B.ei))) {
        switch (ei_event_get_type(ev)) {
        case EI_EVENT_DISCONNECT:
            reply("state lost libei-disconnect");
            exit(3);
        case EI_EVENT_SEAT_ADDED: {
            struct ei_seat *seat = ei_event_get_seat(ev);
            ei_seat_bind_capabilities(seat,
                                      EI_DEVICE_CAP_POINTER,
                                      EI_DEVICE_CAP_SCROLL,
                                      EI_DEVICE_CAP_BUTTON,
                                      EI_DEVICE_CAP_KEYBOARD,
                                      NULL);
            break;
        }
        case EI_EVENT_DEVICE_ADDED: {
            struct ei_device *d = ei_event_get_device(ev);
            if (B.device == NULL &&
                ei_device_has_capability(d, EI_DEVICE_CAP_POINTER) &&
                ei_device_has_capability(d, EI_DEVICE_CAP_SCROLL)) {
                B.device = d;
            }
            break;
        }
        case EI_EVENT_DEVICE_REMOVED:
            if (ei_event_get_device(ev) == B.device) {
                B.device = NULL;
                B.ei_active = false;
            }
            break;
        case EI_EVENT_DEVICE_RESUMED:
            if (ei_event_get_device(ev) == B.device) {
                ei_device_start_emulating(B.device, 1);
                B.ei_active = true;
                reply("state ready backend=ei");
            }
            break;
        case EI_EVENT_DEVICE_PAUSED:
            if (ei_event_get_device(ev) == B.device)
                B.ei_active = false;
            break;
        default:
            break;
        }
        ei_event_unref(ev);
    }
}

static bool
ei_init(void)
{
    B.ei = ei_new(NULL);
    if (B.ei == NULL)
        return false;
    ei_configure_name(B.ei, "Flutter Touchpad");
    if (ei_setup_backend_socket(B.ei, NULL) < 0)
        return false;
    B.mode = MODE_EI;
    reply("state connecting");
    return true;
}

#endif /* HAVE_EI */

/* --------------------------------------------------------------- uinput */

#ifdef HAVE_UINPUT

static int uin_fd = -1;
static int kbd_fd = -1; /* separate virtual keyboard (created on demand) */
static double uin_ax, uin_ay; /* motion accumulator */
static double uin_sy, uin_sx; /* smooth scroll accumulator (pixels) */

#define UIN_NOTCH_PX 20.0 /* pixels per discrete wheel notch */

/*
 * The uinput device is a real multi-touch TOUCHPAD (ABS_MT slots) rather than
 * a mouse. libinput (and therefore Wayland compositors such as Hyprland) then
 * runs the exact same interpretation as the laptop's own touchpad: tap to
 * click, double-tap to select, two-finger scroll/tap, and 3-finger gestures.
 * The phone reports touch states as complete frames so that a dropped frame
 * on a lossy transport self-heals on the next one.
 */
#define MT_SLOTS 5
#define MT_X_MAX 2599
#define MT_Y_MAX 1399
#define MT_RES 26 /* units per mm; pad then looks like ~100x54 mm */

static int mt_id[MT_SLOTS];   /* client touch id per slot, -1 = empty */
static int mt_active[MT_SLOTS];

static void
uin_write(uint16_t type, uint16_t code, int32_t value)
{
    struct input_event ev = {0};
    ev.type = type;
    ev.code = code;
    ev.value = value;
    if (write(uin_fd, &ev, sizeof ev) != (ssize_t)sizeof ev)
        return;
}

static void
uin_syn(void)
{
    uin_write(EV_SYN, SYN_REPORT, 0);
}

static bool
uin_abs(uint16_t code, int min, int max, int res)
{
    struct uinput_abs_setup a = {0};
    a.code = code;
    a.absinfo.minimum = min;
    a.absinfo.maximum = max;
    a.absinfo.resolution = res;
    return ioctl(uin_fd, UI_ABS_SETUP, &a) >= 0;
}

static bool
uin_init(void)
{
    uin_fd = open("/dev/uinput", O_WRONLY | O_CLOEXEC);
    if (uin_fd < 0)
        return false;

    for (int s = 0; s < MT_SLOTS; s++)
        mt_id[s] = -1;

    bool ok = true;
    ok = ioctl(uin_fd, UI_SET_EVBIT, EV_KEY) >= 0 && ok;
    ok = ioctl(uin_fd, UI_SET_EVBIT, EV_ABS) >= 0 && ok;
    ok = ioctl(uin_fd, UI_SET_PROPBIT, INPUT_PROP_POINTER) >= 0 && ok;
    ok = ioctl(uin_fd, UI_SET_PROPBIT, INPUT_PROP_BUTTONPAD) >= 0 && ok;

    if (ok) {
        static const uint16_t btns[] = {
            BTN_LEFT, BTN_MIDDLE, BTN_RIGHT, BTN_SIDE, BTN_EXTRA,
        };
        for (size_t i = 0; i < sizeof btns / sizeof btns[0]; i++)
            ok = ioctl(uin_fd, UI_SET_KEYBIT, btns[i]) >= 0 && ok;
    }
    if (ok) {
        /* libinput only tags a device as a TOUCHPAD when it also exposes
         * the touch-tool keys; keyboard bitmaps would make it a keyboard. */
        static const uint16_t tools[] = {
            BTN_TOUCH, BTN_TOOL_FINGER, BTN_TOOL_DOUBLETAP,
            BTN_TOOL_TRIPLETAP, BTN_TOOL_QUADTAP, BTN_TOOL_QUINTTAP,
        };
        for (size_t i = 0; i < sizeof tools / sizeof tools[0]; i++)
            ok = ioctl(uin_fd, UI_SET_KEYBIT, tools[i]) >= 0 && ok;
    }

    if (ok)
        ok = uin_abs(ABS_MT_SLOT, 0, MT_SLOTS - 1, 0) && ok;
    if (ok)
        ok = uin_abs(ABS_MT_TRACKING_ID, 0, MT_SLOTS * 100, 0) && ok;
    if (ok)
        ok = uin_abs(ABS_MT_POSITION_X, 0, MT_X_MAX, MT_RES) && ok;
    if (ok)
        ok = uin_abs(ABS_MT_POSITION_Y, 0, MT_Y_MAX, MT_RES) && ok;
    if (ok)
        ok = uin_abs(ABS_MT_PRESSURE, 0, 64, 0) && ok;
    if (ok)
        ok = uin_abs(ABS_MT_TOOL_TYPE, 0, 1, 0) && ok;

    if (ok) {
        struct uinput_setup us = {0};
        us.id.bustype = BUS_VIRTUAL;
        us.id.vendor = 0x5446; /* TF */
        us.id.product = 0x4E56; /* NV */
        us.id.version = 1;
        snprintf(us.name, sizeof us.name, "Flutter Touchpad");
        ok = ioctl(uin_fd, UI_DEV_SETUP, &us) >= 0;
    }
    if (ok)
        ok = ioctl(uin_fd, UI_DEV_CREATE) >= 0;

    if (!ok) {
        close(uin_fd);
        uin_fd = -1;
        return false;
    }
    B.mode = MODE_UINPUT;
    reply("state ready backend=uinput");
    return true;
}

/* Push a full touch-state frame into the uinput slots. `t` lines arrive as
 * `t <n> <id>:<x>,<y> [...]` with x,y in 0..1. State-based so lost frames
 * heal by themselves. */
static void
uin_mt_frame(const int *ids, const double *xs, const double *ys, int n)
{
    /* release slots whose touch id is no longer present */
    for (int s = 0; s < MT_SLOTS; s++) {
        if (mt_active[s] < 0)
            continue;
        int found = 0;
        for (int i = 0; i < n; i++)
            if (ids[i] == mt_id[s]) {
                found = 1;
                break;
            }
        if (found)
            continue;
        uin_write(EV_ABS, ABS_MT_SLOT, s);
        uin_write(EV_ABS, ABS_MT_TRACKING_ID, -1);
        mt_active[s] = 0;
    }
    /* (re)activate slots for the active touches and move them */
    for (int i = 0; i < n; i++) {
        int s = -1;
        for (int j = 0; j < MT_SLOTS; j++)
            if (mt_active[j] && mt_id[j] == ids[i]) {
                s = j;
                break;
            }
        if (s < 0)
            for (int j = 0; j < MT_SLOTS; j++)
                if (!mt_active[j]) {
                    s = j;
                    break;
                }
        if (s < 0)
            continue; /* out of slots, drop */
        if (!mt_active[s]) {
            mt_active[s] = 1;
            mt_id[s] = ids[i];
            uin_write(EV_ABS, ABS_MT_SLOT, s);
            uin_write(EV_ABS, ABS_MT_TRACKING_ID, (s + 1) * 10);
        }
        uin_write(EV_ABS, ABS_MT_SLOT, s);
        uin_write(EV_ABS, ABS_MT_POSITION_X, (int)(xs[i] * MT_X_MAX));
        uin_write(EV_ABS, ABS_MT_POSITION_Y, (int)(ys[i] * MT_Y_MAX));
        uin_write(EV_ABS, ABS_MT_PRESSURE, 32);
    }
    uin_syn();
}

static void
uin_mt_clear_all(void)
{
    int any = 0;
    for (int s = 0; s < MT_SLOTS; s++)
        if (mt_active[s])
            any = 1;
    if (!any)
        return;
    for (int s = 0; s < MT_SLOTS; s++) {
        if (!mt_active[s])
            continue;
        uin_write(EV_ABS, ABS_MT_SLOT, s);
        uin_write(EV_ABS, ABS_MT_TRACKING_ID, -1);
        mt_active[s] = 0;
    }
    uin_syn();
}

static void
uin_motion(double dx, double dy)
{
    uin_ax += dx;
    uin_ay += dy;
    int ix = (int)trunc(uin_ax);
    int iy = (int)trunc(uin_ay);
    uin_ax -= ix;
    uin_ay -= iy;
    if (ix)
        uin_write(EV_REL, REL_X, ix);
    if (iy)
        uin_write(EV_REL, REL_Y, iy);
    uin_syn();
}

static void
uin_button(uint32_t btn, bool press)
{
    uin_write(EV_KEY, btn, press ? 1 : 0);
    uin_syn();
}

static void
uin_scroll_smooth(double dx, double dy)
{
    uin_sy += dy;
    uin_sx += dx;
    int ny = (int)trunc(uin_sy / UIN_NOTCH_PX);
    int nx = (int)trunc(uin_sx / UIN_NOTCH_PX);
    uin_sy -= ny * UIN_NOTCH_PX;
    uin_sx -= nx * UIN_NOTCH_PX;
    if (ny) {
        uin_write(EV_REL, REL_WHEEL_HI_RES, -ny * 120);
        uin_write(EV_REL, REL_WHEEL, ny > 0 ? -1 : 1);
    }
    if (nx) {
        uin_write(EV_REL, REL_HWHEEL_HI_RES, nx * 120);
        uin_write(EV_REL, REL_HWHEEL, nx > 0 ? 1 : -1);
    }
    uin_syn();
}

static void
uin_scroll_discrete(int dx, int dy)
{
    if (dy) {
        uin_write(EV_REL, REL_WHEEL_HI_RES, -dy * 120);
        uin_write(EV_REL, REL_WHEEL, -dy);
    }
    if (dx) {
        uin_write(EV_REL, REL_HWHEEL_HI_RES, dx * 120);
        uin_write(EV_REL, REL_HWHEEL, dx);
    }
    uin_syn();
}

static void
uin_key(uint32_t key, bool press)
{
    /* Keyboard keys are only registered on the separate keyboard device, so
     * route through it when active; the touchpad only exposes BTN_* keys. */
    if (kbd_fd >= 0) {
        struct input_event ev = {0};
        ev.type = EV_KEY;
        ev.code = (uint16_t)key;
        ev.value = press ? 1 : 0;
        if (write(kbd_fd, &ev, sizeof ev) != (ssize_t)sizeof ev)
            return;
        ev.type = EV_SYN;
        ev.code = SYN_REPORT;
        ev.value = 0;
        (void)write(kbd_fd, &ev, sizeof ev);
        return;
    }
    uin_write(EV_KEY, key, press ? 1 : 0);
    uin_syn();
}

static bool
uin_kbd_init(void)
{
    if (kbd_fd >= 0)
        return true;
    int fd = open("/dev/uinput", O_WRONLY | O_CLOEXEC);
    if (fd < 0)
        return false;
    bool ok = ioctl(fd, UI_SET_EVBIT, EV_KEY) >= 0;
    if (ok)
        for (uint16_t c = 1; c < 256 && ok; c++)
            ok = ioctl(fd, UI_SET_KEYBIT, c) >= 0;
    if (ok) {
        struct uinput_setup us = {0};
        us.id.bustype = BUS_VIRTUAL;
        us.id.vendor = 0x5446; /* TF */
        us.id.product = 0x4B42; /* KB */
        us.id.version = 1;
        snprintf(us.name, sizeof us.name, "Flutter Keyboard");
        ok = ioctl(fd, UI_DEV_SETUP, &us) >= 0;
    }
    if (ok)
        ok = ioctl(fd, UI_DEV_CREATE) >= 0;
    if (!ok) {
        close(fd);
        return false;
    }
    kbd_fd = fd;
    return true;
}

static void
uin_kbd_destroy(void)
{
    if (kbd_fd < 0)
        return;
    ioctl(kbd_fd, UI_DEV_DESTROY); /* releases all held keys */
    close(kbd_fd);
    kbd_fd = -1;
}

#endif /* HAVE_UINPUT */

/* ------------------------------------------------------------------ x11 */

#ifdef HAVE_X11

static bool
x11_init(void)
{
    if (getenv("DISPLAY") == NULL)
        return false;
    B.dpy = XOpenDisplay(NULL);
    if (B.dpy == NULL)
        return false;
    int ev, er, major, minor;
    if (!XTestQueryExtension(B.dpy, &ev, &er, &major, &minor)) {
        XCloseDisplay(B.dpy);
        B.dpy = NULL;
        return false;
    }
    B.x11_xtest = true;
    B.mode = MODE_X11;
    reply("state ready backend=x11");
    return true;
}

#endif /* HAVE_X11 */

/* ------------------------------------------------------------- commands */

static bool
ready(void)
{
    switch (B.mode) {
    case MODE_EI:
        return B.ei != NULL && B.device != NULL && B.ei_active;
#ifdef HAVE_UINPUT
    case MODE_UINPUT:
        return uin_fd >= 0;
#endif
    case MODE_X11:
        return B.dpy != NULL && B.x11_xtest;
    default:
        return false;
    }
}

static void
do_motion(double dx, double dy)
{
    if (!ready()) {
        reply("err not-ready");
        return;
    }
    switch (B.mode) {
    case MODE_EI:
        ei_device_pointer_motion(B.device, dx, dy);
        break;
#ifdef HAVE_UINPUT
    case MODE_UINPUT:
        uin_motion(dx, dy);
        break;
#endif
    case MODE_X11:
        B.x11_ax += dx;
        B.x11_ay += dy;
        XTestFakeRelativeMotionEvent(B.dpy, -1,
                                     (int)trunc(B.x11_ax),
                                     (int)trunc(B.x11_ay));
        B.x11_ax -= trunc(B.x11_ax);
        B.x11_ay -= trunc(B.x11_ay);
        XFlush(B.dpy);
        break;
    default:
        break;
    }
}

static uint32_t
btn_code(int btn)
{
    switch (btn) {
    case 1: return 0x110; /* BTN_LEFT */
    case 2: return 0x112; /* BTN_MIDDLE */
    case 3: return 0x111; /* BTN_RIGHT */
    case 4: return 0x113; /* BTN_SIDE */
    case 5: return 0x114; /* BTN_EXTRA */
    default: return 0;
    }
}

static int
x11_btn(int btn)
{
    switch (btn) {
    case 1: return 1; /* left */
    case 2: return 2; /* middle */
    case 3: return 3; /* right */
    case 4: return 8; /* side */
    case 5: return 9; /* extra */
    default: return 0;
    }
}

static void
do_button(int btn, bool press)
{
    if (!ready()) {
        reply("err not-ready");
        return;
    }
    uint32_t code = btn_code(btn);
    if (code == 0) {
        reply("err bad-button");
        return;
    }
    switch (B.mode) {
    case MODE_EI:
        ei_device_button_button(B.device, code, press);
        break;
#ifdef HAVE_UINPUT
    case MODE_UINPUT:
        uin_button(code, press);
        break;
#endif
    case MODE_X11: {
        int c = x11_btn(btn);
        XTestFakeButtonEvent(B.dpy, c, press, CurrentTime);
        XFlush(B.dpy);
        break;
    }
    default:
        break;
    }
    if (btn >= 1 && btn <= 5) {
        if (press)
            held_btns |= (1u << (btn - 1));
        else
            held_btns &= ~(1u << (btn - 1));
    }
}

/* A full click in a single command: press, brief hold, release. Sending this
 * as one line instead of a press/release pair makes clicks survive lossy
 * transports (e.g. a flaky adb reverse over USB) where the second packet in a
 * pair is frequently dropped, which previously left the button stuck. */
static void
do_click(int btn)
{
    do_button(btn, true);
    usleep(20000);
    do_button(btn, false);
}

static void
do_scroll_smooth(double dx, double dy)
{
    if (!ready()) {
        reply("err not-ready");
        return;
    }
    switch (B.mode) {
    case MODE_EI:
        if (dx != 0 || dy != 0)
            ei_device_scroll_delta(B.device, dx, dy);
        break;
#ifdef HAVE_UINPUT
    case MODE_UINPUT:
        uin_scroll_smooth(dx, dy);
        break;
#endif
    case MODE_X11: {
        const double NOTCH = 40.0;
        B.x11_sy += dy;
        B.x11_sx += dx;
        int v = (int)(B.x11_sy / NOTCH);
        int h = (int)(B.x11_sx / NOTCH);
        B.x11_sy -= v * NOTCH;
        B.x11_sx -= h * NOTCH;
        for (int i = 0; i < abs(v); i++) {
            int b = v > 0 ? 5 : 4; /* down / up */
            XTestFakeButtonEvent(B.dpy, b, True, CurrentTime);
            XTestFakeButtonEvent(B.dpy, b, False, CurrentTime);
        }
        for (int i = 0; i < abs(h); i++) {
            int b = h > 0 ? 7 : 6; /* right / left */
            XTestFakeButtonEvent(B.dpy, b, True, CurrentTime);
            XTestFakeButtonEvent(B.dpy, b, False, CurrentTime);
        }
        XFlush(B.dpy);
        break;
    }
    default:
        break;
    }
}

static void
do_scroll_discrete(int dx, int dy)
{
    if (!ready()) {
        reply("err not-ready");
        return;
    }
    switch (B.mode) {
    case MODE_EI:
        if (dx != 0 || dy != 0) {
            ei_device_scroll_discrete(B.device, dx, dy);
            ei_device_scroll_stop(B.device, true, true);
        }
        break;
#ifdef HAVE_UINPUT
    case MODE_UINPUT:
        uin_scroll_discrete(dx, dy);
        break;
#endif
    case MODE_X11:
        for (int i = 0; i < abs(dy); i++) {
            int b = dy < 0 ? 4 : 5;
            XTestFakeButtonEvent(B.dpy, b, True, CurrentTime);
            XTestFakeButtonEvent(B.dpy, b, False, CurrentTime);
        }
        for (int i = 0; i < abs(dx); i++) {
            int b = dx < 0 ? 6 : 7;
            XTestFakeButtonEvent(B.dpy, b, True, CurrentTime);
            XTestFakeButtonEvent(B.dpy, b, False, CurrentTime);
        }
        XFlush(B.dpy);
        break;
    default:
        break;
    }
}

static void
do_scroll_stop(void)
{
    switch (B.mode) {
    case MODE_EI:
        if (B.device && B.ei_active)
            ei_device_scroll_stop(B.device, true, true);
        break;
#ifdef HAVE_UINPUT
    case MODE_UINPUT:
        uin_sx = 0;
        uin_sy = 0;
        break;
#endif
    case MODE_X11:
        B.x11_sx = 0;
        B.x11_sy = 0;
        break;
    default:
        break;
    }
}

static void
release_all(void)
{
    for (int btn = 1; btn <= 5; btn++) {
        if (!(held_btns & (1u << (btn - 1))))
            continue;
        uint32_t code = btn_code(btn);
        if (code == 0)
            continue;
        switch (B.mode) {
        case MODE_EI:
#ifdef HAVE_EI
            if (B.device)
                ei_device_button_button(B.device, code, false);
#endif
            break;
#ifdef HAVE_UINPUT
        case MODE_UINPUT:
            uin_button(code, false);
            break;
#endif
        case MODE_X11:
#ifdef HAVE_X11
        {
            int c = x11_btn(btn);
            if (c)
                XTestFakeButtonEvent(B.dpy, c, False, CurrentTime);
        }
#endif
            break;
        default:
            break;
        }
    }
    held_btns = 0;

    for (int i = 0; i < nheld_keys; i++) {
        int key = held_keys[i];
        uint32_t code = (uint32_t)key;
        switch (B.mode) {
        case MODE_EI:
#ifdef HAVE_EI
            if (B.device)
                ei_device_keyboard_key(B.device, code, false);
#endif
            break;
#ifdef HAVE_UINPUT
        case MODE_UINPUT:
            uin_key(code, false);
            break;
#endif
        case MODE_X11:
#ifdef HAVE_X11
        {
            KeySym sym = x11_keysym(key);
            KeyCode kc = sym == XK_VoidSymbol ? 0 : XKeysymToKeycode(B.dpy, sym);
            if (kc)
                XTestFakeKeyEvent(B.dpy, kc, False, CurrentTime);
        }
#endif
            break;
        default:
            break;
        }
    }
    nheld_keys = 0;
    do_scroll_stop();
#ifdef HAVE_UINPUT
    if (B.mode == MODE_UINPUT) {
        uin_mt_clear_all();
        uin_kbd_destroy(); /* a new client starts with the keyboard closed */
    }
#endif
#ifdef HAVE_X11
    if (B.mode == MODE_X11)
        XFlush(B.dpy);
#endif
}

#ifdef HAVE_X11
/* Map a raw evdev key code (input-event-codes.h) to its US-layout keysym.
 * Modifier handling (Shift for uppercase/symbols) is left to the X server:
 * the app sends Shift (code 42/54) as a normal key, so typing "!" via the
 * keyboard is Shift+1 exactly like the laptop's real keyboard. */
static KeySym
x11_keysym(int key)
{
    /* Letter rows are physically grouped, not alphabetically sequential. */
    if (key >= 16 && key <= 25) {
        static const KeySym top[] = {
            XK_q, XK_w, XK_e, XK_r, XK_t, XK_y, XK_u, XK_i, XK_o, XK_p,
        };
        return top[key - 16];
    }
    if (key >= 30 && key <= 38) {
        static const KeySym home[] = {
            XK_a, XK_s, XK_d, XK_f, XK_g, XK_h, XK_j, XK_k, XK_l,
        };
        return home[key - 30];
    }
    if (key >= 44 && key <= 50) {
        static const KeySym bot[] = {
            XK_z, XK_x, XK_c, XK_v, XK_b, XK_n, XK_m,
        };
        return bot[key - 44];
    }

    switch (key) {
    case 1:   return XK_Escape;
    case 2:   return XK_1;
    case 3:   return XK_2;
    case 4:   return XK_3;
    case 5:   return XK_4;
    case 6:   return XK_5;
    case 7:   return XK_6;
    case 8:   return XK_7;
    case 9:   return XK_8;
    case 10:  return XK_9;
    case 11:  return XK_0;
    case 12:  return XK_minus;
    case 13:  return XK_equal;
    case 14:  return XK_BackSpace;
    case 15:  return XK_Tab;
    case 26:  return XK_bracketleft;
    case 27:  return XK_bracketright;
    case 28:  return XK_Return;
    case 29:  return XK_Control_L;
    case 39:  return XK_semicolon;
    case 40:  return XK_apostrophe;
    case 41:  return XK_grave;
    case 42:  return XK_Shift_L;
    case 43:  return XK_backslash;
    case 51:  return XK_comma;
    case 52:  return XK_period;
    case 53:  return XK_slash;
    case 54:  return XK_Shift_R;
    case 56:  return XK_Alt_L;
    case 57:  return XK_space;
    case 58:  return XK_Caps_Lock;
    case 59:  return XK_F1;
    case 60:  return XK_F2;
    case 61:  return XK_F3;
    case 62:  return XK_F4;
    case 63:  return XK_F5;
    case 64:  return XK_F6;
    case 65:  return XK_F7;
    case 66:  return XK_F8;
    case 67:  return XK_F9;
    case 68:  return XK_F10;
    case 70:  return XK_Scroll_Lock;
    case 97:  return XK_Control_R;
    case 99:  return XK_Print;
    case 100: return XK_Alt_R;
    case 102: return XK_Home;
    case 103: return XK_Up;
    case 104: return XK_Page_Up;
    case 105: return XK_Left;
    case 106: return XK_Right;
    case 107: return XK_End;
    case 108: return XK_Down;
    case 109: return XK_Page_Down;
    case 110: return XK_Insert;
    case 111: return XK_Delete;
    case 119: return XK_Pause;
    case 125: return XK_Super_L;
    case 126: return XK_Super_R;
    default:  return XK_VoidSymbol;
    }
}
#endif

static void
do_key(int key, bool press)
{
    if (!ready()) {
        reply("err not-ready");
        return;
    }
    /* `k <code>` uses raw evdev key codes (input-event-codes.h); the app sends
     * them unchanged, including modifiers (CTRL=29, SHIFT=42, ALT=56, META=125). */
    uint32_t code = (uint32_t)key;
    switch (B.mode) {
    case MODE_EI:
        ei_device_keyboard_key(B.device, code, press);
        break;
#ifdef HAVE_UINPUT
    case MODE_UINPUT:
        uin_key(code, press);
        break;
#endif
    case MODE_X11: {
        KeySym sym = x11_keysym(key);
        if (sym == XK_VoidSymbol) {
            reply("err bad-key");
            return;
        }
        KeyCode kc = XKeysymToKeycode(B.dpy, sym);
        if (kc == 0) {
            reply("err no-keycode");
            return;
        }
        XTestFakeKeyEvent(B.dpy, kc, press, CurrentTime);
        XFlush(B.dpy);
        break;
    }
    default:
        break;
    }
    if (press) {
        bool found = false;
        for (int i = 0; i < nheld_keys; i++)
            if (held_keys[i] == key) {
                found = true;
                break;
            }
        if (!found && nheld_keys < 64)
            held_keys[nheld_keys++] = key;
    } else {
        for (int i = 0; i < nheld_keys; i++)
            if (held_keys[i] == key) {
                held_keys[i] = held_keys[nheld_keys - 1];
                nheld_keys--;
                break;
            }
    }
}

static void
handle_line(char *line)
{
    dlog("recv: %s", line);
    if (strcmp(line, "ping") == 0) {
        reply("pong");
        return;
    }
    if (strcmp(line, "quit") == 0) {
        exit(0);
    }
    if (strcmp(line, "q") == 0) {
        do_scroll_stop();
        return;
    }
    if (strncmp(line, "m ", 2) == 0) {
        double dx, dy;
        if (sscanf(line + 2, "%lf %lf", &dx, &dy) == 2)
            do_motion(dx, dy);
        else
            reply("err bad-args");
        return;
    }
    if (strncmp(line, "b ", 2) == 0) {
        int btn, st;
        if (sscanf(line + 2, "%d %d", &btn, &st) == 2)
            do_button(btn, st != 0);
        else
            reply("err bad-args");
        return;
    }
    if (strncmp(line, "c ", 2) == 0) {
        int btn;
        if (sscanf(line + 2, "%d", &btn) == 1)
            do_click(btn);
        else
            reply("err bad-args");
        return;
    }
    if (strncmp(line, "t ", 2) == 0) {
#ifdef HAVE_UINPUT
        if (B.mode != MODE_UINPUT) {
            reply("err not-ready");
            return;
        }
        char *p = line + 2;
        long n = strtol(p, &p, 10);
        if (n < 0 || n > MT_SLOTS) {
            reply("err bad-args");
            return;
        }
        int ids[MT_SLOTS];
        double xs[MT_SLOTS], ys[MT_SLOTS];
        int got = 0;
        while (got < n) {
            while (*p == ' ' || *p == ';' || *p == '\t')
                p++;
            if (*p == '\0')
                break;
            long id = strtol(p, &p, 10);
            if (*p != ':') {
                reply("err bad-args");
                return;
            }
            p++;
            double x = strtod(p, &p);
            if (*p != ',') {
                reply("err bad-args");
                return;
            }
            p++;
            double y = strtod(p, &p);
            if (x < 0 || x > 1 || y < 0 || y > 1) {
                reply("err bad-args");
                return;
            }
            ids[got] = (int)id;
            xs[got] = x;
            ys[got] = y;
            got++;
        }
        uin_mt_frame(ids, xs, ys, got);
#else
        reply("err not-ready");
#endif
        return;
    }
    if (strncmp(line, "s ", 2) == 0) {
        double dx, dy;
        if (sscanf(line + 2, "%lf %lf", &dx, &dy) == 2)
            do_scroll_smooth(dx, dy);
        else
            reply("err bad-args");
        return;
    }
    if (strncmp(line, "d ", 2) == 0) {
        int dx, dy;
        if (sscanf(line + 2, "%d %d", &dx, &dy) == 2)
            do_scroll_discrete(dx, dy);
        else
            reply("err bad-args");
        return;
    }
    if (strncmp(line, "kb ", 3) == 0) {
        int st;
        if (sscanf(line + 3, "%d", &st) != 1) {
            reply("err bad-args");
            return;
        }
#ifdef HAVE_UINPUT
        if (B.mode != MODE_UINPUT) {
            reply("err not-ready");
            return;
        }
        if (st) {
            reply(uin_kbd_init() ? "kb on" : "err kbd-failed");
        } else {
            uin_kbd_destroy();
            reply("kb off");
        }
#else
        reply("err not-ready");
#endif
        return;
    }
    if (strncmp(line, "k ", 2) == 0) {
        int key, st;
        if (sscanf(line + 2, "%d %d", &key, &st) == 2)
            do_key(key, st != 0);
        else
            reply("err bad-args");
        return;
    }
    reply("err unknown-command");
}

/* ------------------------------------------------------------------- main */

static void
emit_connected(void)
{
    switch (B.mode) {
    case MODE_EI:
        reply("state connecting");
        break;
#ifdef HAVE_UINPUT
    case MODE_UINPUT:
        reply("state ready backend=uinput");
        break;
#endif
    case MODE_X11:
        reply("state ready backend=x11");
        break;
    default:
        reply("state connecting");
        break;
    }
}

static int
listen_setup(const char *port_str, const char *host_str)
{
    int port = atoi(port_str);
    if (port <= 0 || port > 65535)
        return -1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    /* default loopback-only; "0.0.0.0" or a LAN IP serves the phone over
     * hotspot/wifi directly (see README). inet_addr("0.0.0.0") == INADDR_ANY. */
    sa.sin_addr.s_addr = inet_addr(host_str);
    sa.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) < 0 ||
        listen(fd, 1) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void
run_loop(void)
{
    for (;;) {
        if (listen_fd >= 0) {
            int c = accept(listen_fd, NULL, NULL);
            if (c < 0) {
                if (errno == EINTR)
                    continue;
                perror("accept");
                return;
            }
            in_fd = c;
            out_fd = c;
            dlog("conn: accepted fd=%d", c);
            emit_connected();
        }

        /* serve the current connection */
        bool serve = true;
        while (serve) {
            struct pollfd pfd[2];
            int n = 0;
            int eifd = -1;
#ifdef HAVE_EI
            if (B.mode == MODE_EI && B.ei) {
                eifd = ei_get_fd(B.ei);
                if (eifd >= 0) {
                    pfd[n].fd = eifd;
                    pfd[n].events = POLLIN;
                    pfd[n].revents = 0;
                    n++;
                }
            }
#endif
            pfd[n].fd = in_fd;
            pfd[n].events = POLLIN;
            pfd[n].revents = 0;
            n++;

            int r = poll(pfd, (nfds_t)n, -1);
            if (r < 0) {
                if (errno == EINTR)
                    continue;
                perror("poll");
                return;
            }
            for (int i = 0; i < n; i++) {
                if (pfd[i].fd == in_fd) {
                    if (pfd[i].revents & (POLLHUP | POLLERR | POLLNVAL)) {
                        serve = false;
                    } else if (pfd[i].revents & POLLIN) {
                        if (!read_stdin())
                            serve = false;
                    }
                }
#ifdef HAVE_EI
                if (pfd[i].fd == eifd && pfd[i].revents & POLLIN) {
                    ei_dispatch(B.ei);
                    ei_drain();
                }
#endif
            }
        }

        dlog("conn: closed");
        /* Whatever this client pressed and never released must be undone
         * before the next client takes over (or we exit). */
        release_all();

        if (listen_fd < 0) {
            reply("state lost stdin-closed");
            return;
        }
        close(in_fd);
        in_fd = STDIN_FILENO;
        out_fd = STDOUT_FILENO;
    }
}

int
main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);
    signal(SIGPIPE, SIG_IGN);

    int listen_port_fd = -1;
    const char *host = "127.0.0.1"; /* default: loopback only (safe) */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--host") == 0 && i + 1 < argc)
            host = argv[++i]; /* "0.0.0.0" = reachable from LAN/hotspot */
    }
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--listen") == 0 && i + 1 < argc) {
            listen_port_fd = listen_setup(argv[++i], host);
            if (listen_port_fd < 0) {
                fprintf(stderr, "error: cannot listen on port %s\n", argv[i]);
                return 2;
            }
        }
    }

    const char *be = getenv("TOUCHPAD_BACKEND");
    bool only_ei = be != NULL && strcmp(be, "ei") == 0;
    bool only_uin = be != NULL && strcmp(be, "uinput") == 0;
    bool only_x11 = be != NULL && strcmp(be, "x11") == 0;
    bool auto_sel = be == NULL;

#ifdef HAVE_EI
    if (auto_sel || only_ei) {
        if (ei_init())
            goto done;
        if (only_ei) {
            fprintf(stderr, "error: libei backend unavailable\n");
            return 2;
        }
    }
#else
    if (only_ei) {
        fprintf(stderr, "error: built without libei\n");
        return 2;
    }
#endif

#ifdef HAVE_UINPUT
    if (auto_sel || only_uin) {
        if (uin_init())
            goto done;
        if (only_uin) {
            fprintf(stderr, "error: uinput backend unavailable\n");
            return 2;
        }
    }
#else
    if (only_uin) {
        fprintf(stderr, "error: built without uinput\n");
        return 2;
    }
#endif

#ifdef HAVE_X11
    if (auto_sel || only_x11) {
        if (x11_init())
            goto done;
        if (only_x11) {
            fprintf(stderr, "error: X11 backend unavailable\n");
            return 2;
        }
    }
#else
    if (only_x11) {
        fprintf(stderr, "error: built without X11\n");
        return 2;
    }
#endif

    fprintf(stderr, "error: no usable input backend\n");
    return 2;

done:
    if (listen_port_fd >= 0) {
        listen_fd = listen_port_fd;
        fprintf(stderr, "listening on %s (default 127.0.0.1 = adb reverse; "
                "--host 0.0.0.0 = hotspot/LAN)\n", host);
    }
    run_loop();
    return 0;
}
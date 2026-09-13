/*
 * Windows input daemon counterpart to main.c.
 *
 * Same line protocol over stdin/stdout (local helper) or a loopback socket
 * (`--listen <port>`, phone via `adb reverse tcp:<port> tcp:<port>`).
 *
 *   m  <dx> <dy>      relative pointer motion (floats)
 *   b  <btn> <0|1>    button press/release (1=L 2=M 3=R 4=side 5=extra)
 *   c  <btn>          click (press+release in one command)
 *   s  <dx> <dy>      smooth scroll delta (floats, in pixels)
 *   d  <dx> <dy>      discrete scroll delta (ints, in notches)
 *   q                 end current scroll gesture
 *   k  <key> <0|1>    keyboard key (evdev code passed through unchanged)
 *   kb <0|1>          virtual keyboard on/off (no-op: we inject into the
 *                     session directly, there is no separate device)
 *   ping -> pong
 *   quit
 *
 * Output:
 *   state ready backend=win32
 *   err <message>
 *   pong
 *
 * Injects input with SendInput. Windows has no public virtual-touchpad API
 * like uinput, so there is no raw-touch 't' frame mode: gesture interpretation
 * happens in the Flutter app (synthetic commands), exactly the non-uinput
 * path. Implementation notes:
 *   - evdev key codes are mapped to Windows virtual keys (they coincide with
 *     PS/2 set-1 scan codes in the main letter/number block, but explicit VK
 *     mapping is used for the rest).
 *   - scroll is emitted as wheel notches (WHEEL_DELTA = 120) per 20 px.
 *   - a client that disconnects while holding buttons/keys gets everything
 *     released by release_all() so nothing stays stuck.
 */

#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0601
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <fcntl.h>
#include <io.h>
#include <math.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WHEEL_NOTCH_PX 20.0

/* bit (btn-1) for protocol buttons 1..5 currently held */
static uint32_t held_btns = 0;
static int held_keys[64];
static int nheld_keys = 0;

static double mouse_ax = 0, mouse_ay = 0; /* motion accumulator (subpixel) */
static double scroll_sx = 0, scroll_sy = 0; /* scroll accumulator (px) */

static bool use_sock = false;   /* replies/state go to the socket when true */
static SOCKET out_sock = INVALID_SOCKET;

/* ------------------------------------------------------------- output */

static void
out_write(const char *buf, size_t n)
{
    if (use_sock) {
        if (out_sock != INVALID_SOCKET)
            (void)send(out_sock, buf, (int)n, 0);
        return;
    }
    (void)fwrite(buf, 1, n, stdout);
    (void)fflush(stdout);
}

static void
reply(const char *fmt, ...)
{
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n > 0) {
        if ((size_t)n >= sizeof buf)
            n = (int)(sizeof buf) - 1;
        out_write(buf, (size_t)n);
        out_write("\n", 1);
    }
}

static void
dlog(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    (void)fprintf(stderr, "[helper] ");
    (void)vfprintf(stderr, fmt, ap);
    (void)fprintf(stderr, "\n");
    va_end(ap);
}

/* ------------------------------------------------------------- input */

static void handle_line(char *line);

/* Read the current source (stdin or socket) into inbuf, dispatching complete
 * lines to handle_line(). Returns false when the source is closed. */
static bool
fill_source(void)
{
    char tmp[1024];
    static char inbuf[4096];
    static size_t inlen = 0;

    int r;
    if (use_sock) {
        r = recv(out_sock, tmp, (int)sizeof tmp, 0);
    } else {
        r = (int)_read(_fileno(stdin), tmp, (int)sizeof tmp);
    }
    if (r <= 0)
        return false;
    for (int i = 0; i < r; i++) {
        char c = tmp[i];
        if (c == '\n') {
            if (inlen > 0) {
                if (inbuf[inlen - 1] == '\r')
                    inlen--;
                inbuf[inlen] = '\0';
                handle_line(inbuf);
            }
            inlen = 0;
        } else if (inlen + 1 < sizeof inbuf) {
            inbuf[inlen++] = c;
        } else {
            inlen = 0; /* drop overlong line */
        }
    }
    return true;
}

/* ------------------------------------------------------------- input */

static void
send_mouse_move(int dx, int dy)
{
    INPUT in = {0};
    in.type = INPUT_MOUSE;
    in.mi.dx = dx;
    in.mi.dy = dy;
    in.mi.dwFlags = MOUSEEVENTF_MOVE;
    (void)SendInput(1, &in, sizeof in);
}

static void
do_motion(double dx, double dy)
{
    mouse_ax += dx;
    mouse_ay += dy;
    int ix = (int)trunc(mouse_ax);
    int iy = (int)trunc(mouse_ay);
    mouse_ax -= ix;
    mouse_ay -= iy;
    if (ix || iy)
        send_mouse_move(ix, iy);
}

/* protocol button number (1..5) -> {down flag, up flag, xbutton data} */
static void
do_button(int btn, bool press)
{
    if (btn < 1 || btn > 5) {
        reply("err bad-button");
        return;
    }
    INPUT in = {0};
    in.type = INPUT_MOUSE;
    switch (btn) {
    case 1:
        in.mi.dwFlags = press ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
        break;
    case 2:
        in.mi.dwFlags = press ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
        break;
    case 3:
        in.mi.dwFlags = press ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
        break;
    case 4:
        in.mi.dwFlags = press ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP;
        in.mi.mouseData = XBUTTON1;
        break;
    case 5:
        in.mi.dwFlags = press ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP;
        in.mi.mouseData = XBUTTON2;
        break;
    }
    (void)SendInput(1, &in, sizeof in);
    if (press)
        held_btns |= (1u << (btn - 1));
    else
        held_btns &= ~(1u << (btn - 1));
}

/* Full click in one command, surviving lossy transports that drop one half
 * of a press/release pair. */
static void
do_click(int btn)
{
    do_button(btn, true);
    Sleep(20);
    do_button(btn, false);
}

static void
send_wheel(int notches, bool horizontal)
{
    if (notches == 0)
        return;
    INPUT in = {0};
    in.type = INPUT_MOUSE;
    in.mi.dwFlags = horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
    in.mi.mouseData = (DWORD)(notches * WHEEL_DELTA);
    (void)SendInput(1, &in, sizeof in);
}

static void
do_scroll_smooth(double dx, double dy)
{
    /* dy > 0 (finger down) scrolls content down: negative wheel delta. */
    scroll_sy += dy;
    scroll_sx += dx;
    int ny = (int)trunc(scroll_sy / WHEEL_NOTCH_PX);
    int nx = (int)trunc(scroll_sx / WHEEL_NOTCH_PX);
    scroll_sy -= ny * WHEEL_NOTCH_PX;
    scroll_sx -= nx * WHEEL_NOTCH_PX;
    send_wheel(-ny, false);
    send_wheel(nx, true);
}

static void
do_scroll_discrete(int dx, int dy)
{
    send_wheel(-dy, false);
    send_wheel(dx, true);
}

static void
do_scroll_stop(void)
{
    scroll_sx = 0;
    scroll_sy = 0;
}

/* ----------------------------------------------------------- keyboard */

typedef struct {
    WORD vk;
    bool ext;
} KeyMap;

static const KeyMap KEY_NONE = {0, false};

static KeyMap
key_vk(int code)
{
    if (code >= 16 && code <= 25) {
        static const WORD top[] = {
            'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P',
        };
        return (KeyMap){top[code - 16], false};
    }
    if (code >= 30 && code <= 38) {
        static const WORD home[] = {
            'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L',
        };
        return (KeyMap){home[code - 30], false};
    }
    if (code >= 44 && code <= 50) {
        static const WORD bot[] = {
            'Z', 'X', 'C', 'V', 'B', 'N', 'M',
        };
        return (KeyMap){bot[code - 44], false};
    }

    switch (code) {
    case 1:  return (KeyMap){VK_ESCAPE, false};
    case 2:  return (KeyMap){'1', false};
    case 3:  return (KeyMap){'2', false};
    case 4:  return (KeyMap){'3', false};
    case 5:  return (KeyMap){'4', false};
    case 6:  return (KeyMap){'5', false};
    case 7:  return (KeyMap){'6', false};
    case 8:  return (KeyMap){'7', false};
    case 9:  return (KeyMap){'8', false};
    case 10: return (KeyMap){'9', false};
    case 11: return (KeyMap){'0', false};
    case 12: return (KeyMap){VK_OEM_MINUS, false};
    case 13: return (KeyMap){VK_OEM_PLUS, false};
    case 14: return (KeyMap){VK_BACK, false};
    case 15: return (KeyMap){VK_TAB, false};
    case 26: return (KeyMap){VK_OEM_4, false};   /* [ */
    case 27: return (KeyMap){VK_OEM_6, false};   /* ] */
    case 28: return (KeyMap){VK_RETURN, false};
    case 29: return (KeyMap){VK_CONTROL, false};
    case 39: return (KeyMap){VK_OEM_1, false};   /* ; */
    case 40: return (KeyMap){VK_OEM_7, false};   /* ' */
    case 41: return (KeyMap){VK_OEM_3, false};   /* ` */
    case 42: return (KeyMap){VK_SHIFT, false};
    case 43: return (KeyMap){VK_OEM_5, false};   /* \ */
    case 51: return (KeyMap){VK_OEM_COMMA, false};
    case 52: return (KeyMap){VK_OEM_PERIOD, false};
    case 53: return (KeyMap){VK_OEM_2, false};   /* / */
    case 54: return (KeyMap){VK_RSHIFT, false};
    case 56: return (KeyMap){VK_MENU, false};
    case 57: return (KeyMap){VK_SPACE, false};
    case 58: return (KeyMap){VK_CAPITAL, false};
    case 59: return (KeyMap){VK_F1, false};
    case 60: return (KeyMap){VK_F2, false};
    case 61: return (KeyMap){VK_F3, false};
    case 62: return (KeyMap){VK_F4, false};
    case 63: return (KeyMap){VK_F5, false};
    case 64: return (KeyMap){VK_F6, false};
    case 65: return (KeyMap){VK_F7, false};
    case 66: return (KeyMap){VK_F8, false};
    case 67: return (KeyMap){VK_F9, false};
    case 68: return (KeyMap){VK_F10, false};
    /* evdev 69/70 are Num Lock / Scroll Lock; the app labels F11/F12 but
     * passes those raw codes, so keep behavior identical to the Linux
     * helper which forwards them verbatim. */
    case 69: return (KeyMap){VK_NUMLOCK, false};
    case 70: return (KeyMap){VK_SCROLL, false};
    case 97: return (KeyMap){VK_RCONTROL, true};
    case 99: return (KeyMap){VK_SNAPSHOT, false};
    case 100: return (KeyMap){VK_RMENU, true};
    case 102: return (KeyMap){VK_HOME, false};
    case 103: return (KeyMap){VK_UP, true};
    case 104: return (KeyMap){VK_PRIOR, true};
    case 105: return (KeyMap){VK_LEFT, true};
    case 106: return (KeyMap){VK_RIGHT, true};
    case 107: return (KeyMap){VK_END, false};
    case 108: return (KeyMap){VK_DOWN, true};
    case 109: return (KeyMap){VK_NEXT, true};
    case 110: return (KeyMap){VK_INSERT, true};
    case 111: return (KeyMap){VK_DELETE, true};
    case 119: return (KeyMap){VK_PAUSE, false};
    case 125: return (KeyMap){VK_LWIN, true};
    case 126: return (KeyMap){VK_RWIN, true};
    default:  return KEY_NONE;
    }
}

static void
do_key(int key, bool press)
{
    KeyMap m = key_vk(key);
    if (m.vk == 0) {
        reply("err bad-key");
        return;
    }
    INPUT in = {0};
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = m.vk;
    in.ki.dwFlags = (m.ext ? KEYEVENTF_EXTENDEDKEY : 0) |
                    (press ? 0 : KEYEVENTF_KEYUP);
    (void)SendInput(1, &in, sizeof in);

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

/* --------------------------------------------------------------- misc */

static void
release_all(void)
{
    for (int btn = 1; btn <= 5; btn++)
        if (held_btns & (1u << (btn - 1)))
            do_button(btn, false);
    held_btns = 0;

    for (int i = 0; i < nheld_keys; i++)
        do_key(held_keys[i], false);
    nheld_keys = 0;

    do_scroll_stop();
}

/* ------------------------------------------------------------- commands */

static void
handle_line(char *line)
{
    dlog("recv: %s", line);
    if (strcmp(line, "ping") == 0) {
        reply("pong");
        return;
    }
    if (strcmp(line, "quit") == 0)
        exit(0);
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
        /* Single injected session: nothing to create/destroy. */
        reply(st ? "kb on" : "kb off");
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
    /* `t <n> ...` raw touch frames need a virtual touchpad device (uinput);
     * Windows has no public equivalent, so the app's raw-touch mode is off
     * (backend=win32) and frames are never sent. Reject just in case. */
    if (strncmp(line, "t ", 2) == 0) {
        reply("err not-ready");
        return;
    }
    reply("err unknown-command");
}

/* ------------------------------------------------------------- serving */

static void
serve(void)
{
    while (fill_source())
        ;
    dlog("conn: closed");
    release_all();
}

static void
wsd(const char *msg)
{
    dlog("wait: %s (%lu)", msg, (unsigned long)WSAGetLastError());
}

int
main(int argc, char **argv)
{
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);

    SOCKET listen_sock = INVALID_SOCKET;
    const char *port = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--listen") == 0 && i + 1 < argc)
            port = argv[++i];
    }

    if (port != NULL) {
        int pnum = atoi(port);
        if (pnum <= 0 || pnum > 65535) {
            fprintf(stderr, "error: invalid port %s\n", port);
            return 2;
        }
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            fprintf(stderr, "error: WSAStartup failed\n");
            return 2;
        }
        listen_sock = socket(AF_INET, SOCK_STREAM, 0);
        if (listen_sock == INVALID_SOCKET) {
            wsd("socket");
            return 2;
        }
        int one = 1;
        setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, (const char *)&one,
                   sizeof one);
        struct sockaddr_in sa = {0};
        sa.sin_family = AF_INET;
        sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        sa.sin_port = htons((unsigned short)pnum);
        if (bind(listen_sock, (struct sockaddr *)&sa, sizeof sa) == SOCKET_ERROR ||
            listen(listen_sock, 1) == SOCKET_ERROR) {
            wsd("bind/listen");
            closesocket(listen_sock);
            return 2;
        }
        fprintf(stderr,
                "listening on 127.0.0.1 (from phone: adb reverse tcp:%s "
                "tcp:%s)\n", port, port);
    }

    if (listen_sock == INVALID_SOCKET) {
        /* Local helper: raw stdin/stdout. SendInput is always available, so
         * announce ready straight away. */
        reply("state ready backend=win32");
        serve();
        reply("state lost stdin-closed");
    } else {
        for (;;) {
            struct sockaddr_in c = {0};
            int clen = (int)sizeof c;
            SOCKET cs = accept(listen_sock, (struct sockaddr *)&c, &clen);
            if (cs == INVALID_SOCKET) {
                wsd("accept");
                break;
            }
            use_sock = true;
            out_sock = cs;
            reply("state ready backend=win32");
            serve();
            closesocket(cs);
            use_sock = false;
            out_sock = INVALID_SOCKET;
        }
        closesocket(listen_sock);
    }
    return 0;
}
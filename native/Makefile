CC      ?= cc
OUT     ?= touchpad-helper

CFLAGS  ?= -O2 -Wall -Wextra -std=gnu11

PKG :=
LIBS :=

# libei -> preferred backend (portals on GNOME/KDE)
HAVE_EI := $(shell pkg-config --exists libei-1.0 && echo 1 || echo 0)
ifeq ($(HAVE_EI),1)
PKG += libei-1.0
CFLAGS += -DHAVE_EI=1
endif

# uinput -> Wayland on compositors without the libei portal (e.g. Hyprland)
HAVE_UIN := $(shell test -f /usr/include/linux/uinput.h && echo 1 || echo 0)
ifeq ($(HAVE_UIN),1)
CFLAGS += -DHAVE_UINPUT=1
endif

# xtst -> X11 fallback backend
HAVE_XTST := $(shell pkg-config --exists xtst && echo 1 || echo 0)
ifeq ($(HAVE_XTST),1)
PKG += xtst x11
CFLAGS += -DHAVE_X11=1
endif

ifeq ($(PKG),)
$(error none of libei-1.0 or xtst found via pkg-config; cannot build any backend)
endif

CFLAGS += $(shell pkg-config --cflags $(PKG))
LIBS   += $(shell pkg-config --libs $(PKG))
LIBS   += -lm

$(OUT): main.c
	$(CC) $(CFLAGS) -o $@ main.c $(LIBS)

clean:
	rm -f $(OUT)

.PHONY: clean
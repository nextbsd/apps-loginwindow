# Copyright (c) 2026, Joseph Maloney
# SPDX-License-Identifier: BSD-2-Clause
#
# loginwindow for the NextBSD WindowServer.
#
#   gmake
#   gmake install     # as root; DESTDIR=... works
#
# Installs loginwindow.app to /System/Library/CoreServices, with its
# LaunchDaemon plist inside the app's Resources, and, only if there is none
# yet, the PAM service to /etc/pam.d/loginwindow.

ifeq ($(GNUSTEP_MAKEFILES),)
  GNUSTEP_MAKEFILES := $(shell gnustep-config --variable=GNUSTEP_MAKEFILES 2>/dev/null)
endif
ifeq ($(GNUSTEP_MAKEFILES),)
  $(error GNUSTEP_MAKEFILES is not set; source /System/Library/Makefiles/GNUstep.sh)
endif

# A system component: keep gnustep-make from creating Local domain dirs.
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = loginwindow
loginwindow_INSTALL_DIR = $(DESTDIR)/System/Library/CoreServices

loginwindow_OBJC_FILES = \
	Source/main.m \
	Source/LWAppDelegate.m \
	Source/LWLoginView.m \
	Source/LWAuth.m \
	Source/LWSession.m

loginwindow_RESOURCE_FILES = \
	Resources/session \
	Resources/SessionApps \
	Resources/Cube.png \
	Resources/Fonts

ADDITIONAL_OBJCFLAGS += -Wall -Wno-import
ADDITIONAL_GUI_LIBS += -lWindowServerClient -lfontconfig -lpam -lutil

LAUNCHD_DIR = $(DESTDIR)/System/Library/LaunchDaemons
PAM_DIR = $(DESTDIR)/etc/pam.d

include $(GNUSTEP_MAKEFILES)/application.make
-include GNUmakefile.postamble

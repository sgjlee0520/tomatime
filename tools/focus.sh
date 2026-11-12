#!/bin/sh
# Tomatime "Dumb Mode" helper for the Mac. Install as
#   ~/Library/Application Scripts/com.sgjlee.tomatime/focus.sh   (chmod +x)
# Tomatime runs it with On or Off; it runs your Shortcut "Tomatime On" or "Tomatime Off", which switch the
# "Tomato" Focus. With Share Across Devices on, your iPhone and Apple Watch follow.
exec /usr/bin/shortcuts run "Tomatime $1"

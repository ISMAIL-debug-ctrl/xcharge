#!/bin/zsh
# Pulls the latest XCharge from GitHub, rebuilds, and reinstalls.
# Asks for the Mac password (native prompt) only when the root helper itself changed.
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd "$(dirname "$0")"
GIT=(git -c credential.helper= -c "credential.helper=!gh auth git-credential")

[[ $1 == --no-pull ]] || $GIT pull --ff-only
./build.sh

# Helper: reinstall only if its sources changed (saves a password prompt on UI-only updates).
NEW_HASH=$(cat Sources/Daemon/* Sources/Shared/* Resources/com.ismailx.xcharge.daemon.plist | shasum -a 256 | cut -d' ' -f1)
OLD_HASH=$(cat "/Library/Application Support/XCharge/daemon.hash" 2>/dev/null || true)
if [[ $NEW_HASH != $OLD_HASH ]]; then
  echo "Helper changed — installing (password prompt)"
  SRC=$PWD
  osascript -e "do shell script \"
    launchctl bootout system/com.ismailx.xcharge.daemon 2>/dev/null; sleep 1
    mkdir -p /Library/PrivilegedHelperTools '/Library/Application Support/XCharge'
    install -m 755 -o root -g wheel '$SRC/build/com.ismailx.xcharge.daemon' /Library/PrivilegedHelperTools/
    install -m 644 -o root -g wheel '$SRC/Resources/com.ismailx.xcharge.daemon.plist' /Library/LaunchDaemons/
    launchctl bootstrap system /Library/LaunchDaemons/com.ismailx.xcharge.daemon.plist
    echo $NEW_HASH > '/Library/Application Support/XCharge/daemon.hash'
  \" with administrator privileges with prompt \"XCharge needs to update its battery helper.\""
fi

# App: no password needed.
pkill -x XCharge 2>/dev/null || true
sleep 1
rm -rf /Applications/XCharge.app && cp -R build/XCharge.app /Applications/
open /Applications/XCharge.app
echo "XCharge updated to $(cat VERSION) ($(git rev-parse --short HEAD))"

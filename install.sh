#!/bin/zsh
# First-time install of XCharge. Run:  ./install.sh   (asks for your Mac password once)
set -eu
cd "$(dirname "$0")"

if launchctl print system/com.apphousekitchen.aldente-pro.helper >/dev/null 2>&1 || pgrep -xq AlDente; then
  echo "AlDente is running — two apps writing the same battery keys will fight."
  read "ans?Stop AlDente and its helper now? [y/N] "
  if [[ $ans == [yY] ]]; then
    pkill -x AlDente || true
    sudo launchctl bootout system/com.apphousekitchen.aldente-pro.helper 2>/dev/null || true
  fi
fi

./update.sh --no-pull --force-helper

# Open the menu bar app at login (can be turned off in the panel).
mkdir -p ~/Library/LaunchAgents
cp Resources/com.ismailx.xcharge.app.plist ~/Library/LaunchAgents/
echo "\nXCharge installed — look for it in the menu bar."

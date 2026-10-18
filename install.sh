#!/bin/zsh
# Installs XCharge. Run:  ./install.sh   (asks for your Mac password once)
set -e
cd "$(dirname "$0")"
./build.sh

if launchctl print system/com.apphousekitchen.aldente-pro.helper >/dev/null 2>&1 || pgrep -xq AlDente; then
  echo "\nAlDente is running — two apps writing the same SMC keys will fight."
  read "ans?Stop AlDente and its helper now? [y/N] "
  if [[ $ans == [yY] ]]; then
    pkill -x AlDente || true
    sudo launchctl bootout system/com.apphousekitchen.aldente-pro.helper 2>/dev/null || true
  fi
fi

sudo launchctl bootout system/com.ismailx.xcharge.daemon 2>/dev/null || true
sudo mkdir -p /Library/PrivilegedHelperTools /Users/Shared/XCharge
sudo chmod 777 /Users/Shared/XCharge
sudo install -m 755 -o root -g wheel build/com.ismailx.xcharge.daemon /Library/PrivilegedHelperTools/
sudo install -m 644 -o root -g wheel Resources/com.ismailx.xcharge.daemon.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/com.ismailx.xcharge.daemon.plist
sudo mkdir -p "/Library/Application Support/XCharge"
cat Sources/Daemon/* Sources/Shared/* Resources/com.ismailx.xcharge.daemon.plist | shasum -a 256 | cut -d' ' -f1 \
  | sudo tee "/Library/Application Support/XCharge/daemon.hash" >/dev/null

pkill -x XCharge 2>/dev/null || true
rm -rf /Applications/XCharge.app && cp -R build/XCharge.app /Applications/
mkdir -p ~/Library/LaunchAgents
cp Resources/com.ismailx.xcharge.app.plist ~/Library/LaunchAgents/
launchctl bootout gui/$(id -u)/com.ismailx.xcharge.app 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ismailx.xcharge.app.plist
echo "\nXCharge installed — look for it in the menu bar."

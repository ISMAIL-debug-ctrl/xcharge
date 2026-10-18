#!/bin/zsh
# Removes XCharge and restores normal charging.
launchctl bootout gui/$(id -u)/com.ismailx.xcharge.app 2>/dev/null
rm -f ~/Library/LaunchAgents/com.ismailx.xcharge.app.plist
pkill -x XCharge; rm -rf /Applications/XCharge.app
sudo launchctl bootout system/com.ismailx.xcharge.daemon 2>/dev/null   # daemon re-enables charging on exit
sudo rm -f /Library/LaunchDaemons/com.ismailx.xcharge.daemon.plist /Library/PrivilegedHelperTools/com.ismailx.xcharge.daemon
sudo rm -rf "/Library/Application Support/XCharge" /Users/Shared/XCharge
echo "XCharge removed."

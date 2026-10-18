#!/bin/zsh
# Removes XCharge and restores normal charging.
launchctl bootout gui/$(id -u)/com.ismailx.xcharge.app 2>/dev/null
rm -f ~/Library/LaunchAgents/com.ismailx.xcharge.app.plist
pkill -x XCharge; rm -rf /Applications/XCharge.app ~/Library/Application\ Support/XCharge ~/Library/Logs/XCharge-update.log
sudo launchctl bootout system/com.ismailx.xcharge.daemon 2>/dev/null   # the helper re-enables charging on exit
sudo rm -f /Library/LaunchDaemons/com.ismailx.xcharge.daemon.plist /Library/PrivilegedHelperTools/com.ismailx.xcharge.daemon
sudo rm -rf "/Library/Application Support/XCharge"
[[ -d /Users/Shared/XCharge && ! -L /Users/Shared/XCharge ]] && sudo rm -rf /Users/Shared/XCharge   # pre-1.3 leftovers
echo "XCharge removed."

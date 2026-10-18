#!/bin/zsh
# Removes MacCleaner, its helper and its settings.
launchctl bootout gui/$(id -u)/com.ismailx.maccleaner.app 2>/dev/null
rm -f ~/Library/LaunchAgents/com.ismailx.maccleaner.app.plist
pkill -x MacCleaner; rm -rf /Applications/MacCleaner.app ~/Library/Application\ Support/MacCleaner ~/Library/Logs/MacCleaner-update.log
defaults delete com.ismailx.maccleaner 2>/dev/null
if [[ -e /Library/LaunchDaemons/com.ismailx.maccleaner.helper.plist ]]; then
  sudo launchctl bootout system/com.ismailx.maccleaner.helper 2>/dev/null
  sudo rm -f /Library/LaunchDaemons/com.ismailx.maccleaner.helper.plist /Library/PrivilegedHelperTools/com.ismailx.maccleaner.helper /var/log/maccleaner-helper.log
  sudo rm -rf "/Library/Application Support/MacCleaner"
fi
echo "MacCleaner removed."

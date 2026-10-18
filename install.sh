#!/bin/zsh
# First-time install of MacCleaner. Run:  ./install.sh   (asks for your Mac password once, for the helper)
#   ./install.sh --no-helper   install the app only (maintenance tasks then ask for a password each time)
set -eu
cd "$(dirname "$0")"
xcode-select -p >/dev/null 2>&1 || { echo "Install the Xcode Command Line Tools first:  xcode-select --install"; exit 1; }
./update.sh --no-pull --force-helper "$@"
echo "\nMacCleaner installed. It's in /Applications and in the menu bar."
echo "Tip: give it Full Disk Access (System Settings ▸ Privacy & Security) so it can see the Trash, Mail and Safari data."

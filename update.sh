#!/bin/zsh
# Updates MacCleaner to the latest GitHub *release* (tag v*), rebuilds, and reinstalls.
# The Mac password is asked (native prompt) only when the root helper itself changed.
#   ./update.sh                  pull the latest release, then install
#   ./update.sh --no-pull        install what is checked out (used by install.sh)
#   ./update.sh --no-helper      app only, never touch the helper
set -eu
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
cd "$(dirname "$0")"
GIT=(git -c credential.helper= -c "credential.helper=!gh auth git-credential")
ARGS=" $* "

if [[ $ARGS != *" --no-pull "* ]]; then
  $GIT fetch --tags --quiet origin
  LATEST=$(git tag -l 'v*' --sort=-v:refname | head -1)
  [[ -n $LATEST ]] || { echo "No release found on GitHub"; exit 1; }
  # Only accept a release that is part of the official main branch history.
  git merge-base --is-ancestor "$LATEST" origin/main || { echo "Release $LATEST is not on main — refusing"; exit 1; }
  git merge --ff-only --quiet "$LATEST"
fi

Tools/signing-identity.sh || echo "Could not create the local signing identity, using an ad-hoc signature"
./build.sh

# Root helper: reinstall only when its sources changed (no password prompt for UI-only updates).
SRC_HASH=$(cat Sources/Helper/* Sources/Shared/* Resources/com.ismailx.maccleaner.helper.plist | shasum -a 256 | cut -d' ' -f1)
OLD_HASH=$(cat "/Library/Application Support/MacCleaner/helper.hash" 2>/dev/null || true)
if [[ $ARGS != *" --no-helper "* ]] && [[ $ARGS == *" --force-helper "* || $SRC_HASH != $OLD_HASH ]]; then
  BIN="$PWD/build/com.ismailx.maccleaner.helper"
  PLIST="$PWD/Resources/com.ismailx.maccleaner.helper.plist"
  BIN_SHA=$(shasum -a 256 "$BIN" | cut -d' ' -f1)
  PLIST_SHA=$(shasum -a 256 "$PLIST" | cut -d' ' -f1)

  # Runs as root. Copies into root's private temp dir first and checks the hashes there,
  # so nothing can swap the files between the password prompt and the install.
  ROOT_SCRIPT='set -eu
BIN=$1; PLIST=$2; BIN_SHA=$3; PLIST_SHA=$4; SRC_HASH=$5
T=$(mktemp -d /private/var/root/maccleaner.XXXXXX)
trap "rm -rf $T" EXIT
cp "$BIN" "$T/helper"; cp "$PLIST" "$T/plist"
[[ $(shasum -a 256 "$T/helper" | cut -d" " -f1) == $BIN_SHA ]] || { echo "helper changed during install, aborted" >&2; exit 1 }
[[ $(shasum -a 256 "$T/plist" | cut -d" " -f1) == $PLIST_SHA ]] || { echo "plist changed during install, aborted" >&2; exit 1 }
launchctl bootout system/com.ismailx.maccleaner.helper 2>/dev/null || true
mkdir -p /Library/PrivilegedHelperTools
install -m 755 -o root -g wheel "$T/helper" /Library/PrivilegedHelperTools/com.ismailx.maccleaner.helper
install -m 644 -o root -g wheel "$T/plist" /Library/LaunchDaemons/com.ismailx.maccleaner.helper.plist
D="/Library/Application Support/MacCleaner"
[[ -L $D ]] && rm -f "$D"
mkdir -p "$D"; chown root:wheel "$D"; chmod 755 "$D"
echo "$SRC_HASH" > "$D/helper.hash"
launchctl bootstrap system /Library/LaunchDaemons/com.ismailx.maccleaner.helper.plist'

  echo "Installing the MacCleaner helper (password prompt)…"
  osascript - "$ROOT_SCRIPT" "$BIN" "$PLIST" "$BIN_SHA" "$PLIST_SHA" "$SRC_HASH" <<'OSA'
on run argv
  set cmd to "/bin/zsh -c " & quoted form of (item 1 of argv) & " maccleaner"
  repeat with i from 2 to 6
    set cmd to cmd & " " & quoted form of (item i of argv)
  end repeat
  do shell script cmd with administrator privileges with prompt "MacCleaner wants to install its helper (system caches and maintenance without a password)."
end run
OSA
fi

# App: no password needed.
pkill -x MacCleaner 2>/dev/null || true
sleep 1
rm -rf /Applications/MacCleaner.app && cp -R build/MacCleaner.app /Applications/
open /Applications/MacCleaner.app
echo "MacCleaner updated to $(cat VERSION) ($(git rev-parse --short HEAD 2>/dev/null || echo local))"

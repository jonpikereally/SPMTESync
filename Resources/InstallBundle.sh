#!/bin/bash
# Shared by the running app and the downloadable installer. All tools use
# absolute paths; tests replace those paths in an isolated copy of this file.
set -u

fail() { printf '%s|%s\n' "$1" "$2" >&2; exit 1; }

version_at_least() {
    local required="$1" actual="$2" rmajor rminor rpatch amajor aminor apatch
    [[ "$required" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
    [[ "$actual" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
    IFS=. read -r rmajor rminor rpatch <<< "$required"
    IFS=. read -r amajor aminor apatch <<< "$actual"
    rminor="${rminor:-0}"; rpatch="${rpatch:-0}"
    aminor="${aminor:-0}"; apatch="${apatch:-0}"
    (( 10#$amajor > 10#$rmajor )) && return 0
    (( 10#$amajor == 10#$rmajor )) || return 1
    (( 10#$aminor > 10#$rminor )) && return 0
    (( 10#$aminor == 10#$rminor && 10#$apatch >= 10#$rpatch ))
}

validate() {
    local app="$1" bid="$2" expected="$3" plist executable version minimum file_type architecture
    plist="$app/Contents/Info.plist"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)" == "$bid" ]] \
        || fail LB-109 "The replacement has the wrong bundle identifier."
    executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null) \
        || fail LB-110 "The replacement has no executable."
    [[ -n "$executable" && "$executable" != */* && -x "$app/Contents/MacOS/$executable" ]] \
        || fail LB-110 "The replacement executable is missing or not executable."
    # codesign also accepts signed scripts/text and does not establish that
    # this is a launchable Mach-O executable. file is part of macOS itself;
    # unlike lipo/otool it does not require the Command Line Tools.
    file_type=$(LC_ALL=C /usr/bin/file -b "$app/Contents/MacOS/$executable")
    file_type="${file_type%%$'\n'*}"
    architecture=$(/usr/bin/uname -m)
    [[ "$file_type" == *Mach-O* && "$file_type" == *"executable $architecture"* ]] \
        || fail LB-110 "The replacement is not a Mach-O executable for this Mac."
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null) \
        || fail LB-110 "The replacement has no version."
    [[ -z "$expected" || "$version" == "$expected" ]] \
        || fail LB-110 "The downloaded app is version $version; the update feed promised $expected."
    minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null) \
        || fail LB-110 "The replacement does not declare a supported macOS version."
    version_at_least "$minimum" "$(/usr/bin/sw_vers -productVersion)" \
        || fail LB-110 "The replacement requires macOS $minimum or later."
    /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
        || fail LB-110 "The replacement is damaged or its signature is invalid."
    /usr/bin/codesign --verify --deep --strict --arch "$architecture" "$app" >/dev/null 2>&1 \
        || fail LB-110 "The replacement does not support this Mac's architecture."
}

case "${1:-}" in
prepare)
    [[ $# == 5 ]] || fail LB-111 "Invalid preparation arguments."
    NEW="$2"; STAGED="$3"; BID="$4"; EXPECTED="$5"
    validate "$NEW" "$BID" "$EXPECTED"
    [[ ! -e "$STAGED" ]] || fail LB-111 "The staging path already exists."
    /usr/bin/ditto --norsrc "$NEW" "$STAGED" 2>/dev/null \
        || fail LB-111 "Couldn't stage the replacement; the installed app was kept."
    /usr/bin/xattr -dr com.apple.quarantine "$STAGED" >/dev/null 2>&1 || true
    /usr/bin/codesign --force --sign - "$STAGED" >/dev/null 2>&1 \
        || fail LB-110 "Couldn't sign the staged replacement; the installed app was kept."
    validate "$STAGED" "$BID" "$EXPECTED"
    ;;
swap)
    [[ $# == 7 ]] || fail LB-111 "Invalid replacement arguments."
    PID="$2"; STAGED="$3"; DEST="$4"; BID="$5"; MARKER="$6"; EXPECTED="$7"
    STAGE_ROOT="$(dirname "$STAGED")"
    trap 'rm -rf "$STAGE_ROOT"' EXIT
    mark_failure() { mkdir -p "$(dirname "$MARKER")"; printf 'LB-112|%s\n' "$1" > "$MARKER"; }
    # A hung shutdown must never turn into replacing an app that is still running.
    if [[ "$PID" != 0 ]]; then
        for ((attempt = 0; attempt < 150; attempt++)); do
            kill -0 "$PID" 2>/dev/null || break
            /bin/sleep 0.2
        done
        if kill -0 "$PID" 2>/dev/null; then
            mark_failure "The app did not finish quitting; its installed copy was kept."
            exit 1
        fi
    fi
    if ! (validate "$STAGED" "$BID" "$EXPECTED"); then
        mark_failure "The staged replacement failed validation; the installed copy was kept."
        [[ "$PID" == 0 ]] || /usr/bin/open "$DEST" >/dev/null 2>&1
        exit 1
    fi
    # The previous version is kept for recovery, but never in the Applications
    # folder: it goes beside the failure marker (Application Support), in a
    # .noindex folder so Spotlight and Launchpad don't offer it as a second
    # copy of the app. Moving it there is a rename on the same volume.
    BACKUP_DIR="$(dirname "$MARKER")/Previous Version.noindex"
    BACKUP="$BACKUP_DIR/$(basename "$DEST" .app).$$.app"
    PREVIOUS="$BACKUP_DIR/$(basename "$DEST")"
    HAD_OLD=0
    if [[ -e "$DEST" ]]; then
        if ! mkdir -p "$BACKUP_DIR" || [[ -e "$BACKUP" ]] || ! /bin/mv "$DEST" "$BACKUP"; then
            mark_failure "Couldn't move the installed app aside; its installed copy was kept."
            [[ "$PID" == 0 ]] || /usr/bin/open "$DEST" >/dev/null 2>&1
            exit 1
        fi
        HAD_OLD=1
    fi
    rollback() {
        local detail="$1" restored=0
        rm -rf "$DEST"
        if [[ "$HAD_OLD" == 1 ]]; then
            if /bin/mv "$BACKUP" "$DEST"; then
                detail="$detail The previous version was restored."
                restored=1
            else
                detail="$detail The previous version is safe at $BACKUP; restore it manually."
            fi
        fi
        # The restored app reads the marker as soon as it launches.
        mark_failure "$detail"
        [[ "$restored" == 0 ]] || /usr/bin/open "$DEST" >/dev/null 2>&1 || true
        exit 1
    }
    /bin/mv "$STAGED" "$DEST" \
        || rollback "Couldn't put the staged replacement in place."
    /usr/bin/tccutil reset Microphone "$BID" >/dev/null 2>&1 || true
    /usr/bin/open "$DEST" \
        || rollback "The replacement couldn't be opened."
    # LaunchServices accepting open does not guarantee the app stays up. Keep
    # the working predecessor (one, replacing any older one) so a subsequent
    # startup failure remains recoverable.
    if [[ "$HAD_OLD" == 1 ]]; then
        rm -rf "$PREVIOUS"
        /bin/mv "$BACKUP" "$PREVIOUS" || true
    fi
    ;;
*) fail LB-111 "Unknown installation operation." ;;
esac

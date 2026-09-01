#!/bin/bash
# Renames files/directories under /tnfs to uppercase names so CP/M clients
# (which always request UPPERCASE paths) can reach content added with
# lowercase names by other means (scp, rsync, tarballs, etc).
ROOT="/tnfs"
LOG="/var/log/tnfs-case-fix.log"

# -depth: process each directory's contents before the directory itself,
# so a parent dir's own rename never invalidates paths already queued for
# its children.
find "$ROOT" -depth -mindepth 1 | while IFS= read -r path; do
    dir=$(dirname "$path")
    base=$(basename "$path")
    upper=$(echo "$base" | tr '[:lower:]' '[:upper:]')
    if [ "$base" != "$upper" ]; then
        target="$dir/$upper"
        if [ -e "$target" ]; then
            echo "$(date '+%F %T') SKIP (target exists): $path -> $target" >> "$LOG"
        else
            mv -n "$path" "$target" && echo "$(date '+%F %T') RENAMED: $path -> $target" >> "$LOG"
        fi
    fi
done

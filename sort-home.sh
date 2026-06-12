#!/usr/bin/env bash

out="home-stats.txt"
printf 'User\tLastEdit\tSize\n' > "$out"

{
  for dir in /home/*
  do
    [ -d "$dir" ] || continue
    user=$(basename "$dir")

    # find the newest file’s mtime in seconds since epoch
    newest_ts=$(find "$dir" -type f -printf '%T@\n' 2>/dev/null \
                | sort -n | tail -1)

    if [ -z "$newest_ts" ]; then
      last_edit="N/A"
    else
      last_edit=$(date -d "@${newest_ts%.*}" '+%Y-%m-%d %H:%M:%S')
    fi

    size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    printf '%s\t%s\t%s\n' "$user" "$last_edit" "$size"
  done
} | sort >> "$out"

#!/bin/bash
# resolve-file-refs.sh — Replace @"path" file references with inline content
# Usage: echo "message with @\"/path/file\" refs" | bash resolve-file-refs.sh <urc_root>
# Outputs resolved message on stdout. Safe for content with special chars.
# Falls back to passthrough if python3 is unavailable (safe default — @refs pass through unmodified).

URC_ROOT="${1:?Usage: resolve-file-refs.sh <urc_root>}"
MSG=$(cat)

# Python fallback: if python3 unavailable, pass through unmodified
# This is the safe default — @"path" refs are Claude-specific but harmless as literal text
if ! command -v python3 >/dev/null 2>&1; then
    printf '%s' "$MSG"
    exit 0
fi

# Use env var to pass URC_ROOT safely (no shell interpolation in python -c string)
export URC_RESOLVE_ROOT="$URC_ROOT"
printf '%s' "$MSG" | python3 -c "
import re, sys, os, shutil

msg = sys.stdin.read()
handoff_dir = os.path.join(os.environ['URC_RESOLVE_ROOT'], '.urc', 'handoffs')

def replace_ref(match):
    fpath = match.group(1)
    if not os.path.isfile(fpath):
        return match.group(0)  # Leave as-is if file doesn't exist
    fsize = os.path.getsize(fpath)
    if fsize < 1024:
        try:
            with open(fpath, 'r') as f:
                content = f.read()
            return f'{fpath}:\n{content}'
        except Exception:
            return match.group(0)
    else:
        os.makedirs(handoff_dir, exist_ok=True)
        dest = os.path.join(handoff_dir, os.path.basename(fpath))
        shutil.copy2(fpath, dest)
        return f'[File: {dest} ({fsize} bytes)]'

result = re.sub(r'@\"([^\"]+)\"', replace_ref, msg)
sys.stdout.write(result)
" || printf '%s' "$MSG"  # Fallback: passthrough on any Python error

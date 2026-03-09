#!/usr/bin/env bash
# urc-status.sh -- Fleet status for instant /urc status command
# Output is plain text, displayed directly via decision:block

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DB_PATH="$PROJECT_ROOT/.urc/coordination.db"
VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"

if [ ! -f "$DB_PATH" ]; then
    echo "No URC database found."
    exit 0
fi

"$VENV_PYTHON" -c "
import sqlite3, time

db = sqlite3.connect('$DB_PATH')
agents = db.execute('SELECT pane_id, cli, role, label, status, last_heartbeat FROM agents ORDER BY last_heartbeat DESC').fetchall()
db.close()

if not agents:
    print('No agents registered.')
else:
    now = time.time()
    # Group by role
    bridges = [a for a in agents if a[2] == 'bridge']
    engineers = [a for a in agents if a[2] == 'engineer']
    others = [a for a in agents if a[2] not in ('bridge', 'engineer')]

    alive_count = sum(1 for a in agents if now - a[5] < 300)
    print(f'Fleet: {len(agents)} agents ({alive_count} alive)')
    print()

    if bridges:
        print(f'Bridges ({len(bridges)}):')
        for a in bridges[:10]:
            age = int(now - a[5])
            status = 'alive' if age < 300 else f'stale ({age}s)'
            label = a[3] or ''
            print(f'  {a[0]} {label} [{status}]')

    if engineers:
        print(f'Engineers ({len(engineers)}):')
        for a in engineers[:10]:
            age = int(now - a[5])
            status = 'alive' if age < 300 else f'stale ({age}s)'
            print(f'  {a[0]} {a[1]} [{status}]')

    if others:
        print(f'Other ({len(others)}):')
        for a in others[:10]:
            age = int(now - a[5])
            status = 'alive' if age < 300 else f'stale ({age}s)'
            label = a[3] or a[2]
            print(f'  {a[0]} {a[1]} {label} [{status}]')
" 2>/dev/null

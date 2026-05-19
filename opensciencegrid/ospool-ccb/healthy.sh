#!/bin/bash

failures=$(supervisorctl status | grep -Ev 'container_cleanup|RUNNING')
if [ -n "$failures" ]; then
    failures=$(echo $failures | sed -E 's/ +/ /' | xargs)
    echo "supervisord non-RUNNING service: $failures" >&2
    exit 2
fi

container_start_time=$(stat -c %Z /proc/1)  # ctime, epoch time

procs_z=$(ps axo pid,stat | awk '$2 ~ /^Z/ { print $1 }' | wc -l)
if [ "$procs_z" -gt 3 ]; then
    echo "Found $procs_z zombie (Z) processes" >&2
    exit 4
fi

procs_d=$(ps axo pid,stat | awk '$2 ~ /^D/ { print $1 }' | wc -l)
if [ "$procs_d" -gt 15 ]; then
    echo "Found $procs_d uninterruptible (D) processes" >&2
    exit 5
fi

exit 0


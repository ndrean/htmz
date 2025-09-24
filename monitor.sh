#!/bin/bash
PID=$(pgrep htmz)

if [ -z "$PID" ]; then
    echo "htmz process not found"
    exit 1
fi

echo "Monitoring htmz process (PID: $PID)"
echo "Time,RSS(MB),VSZ(MB),CPU%"

while kill -0 $PID 2>/dev/null; do
    TIME=$(date +"%H:%M:%S")
    ps -p $PID -o rss=,vsz=,pcpu= | awk -v time="$TIME" '{printf "%s,%.1f,%.1f,%.1f\n", time, $1/1024, $2/1024, $3}'
    sleep 5
done

echo "Process $PID has terminated"
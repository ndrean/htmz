#!/bin/bash
PID=$(pgrep htmz)

if [ -z "$PID" ]; then
    echo "htmz process not found"
    exit 1
fi

# Get CPU count for normalization
CPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "1")

# Output file (default to zig_monitor.csv if not using redirection)
OUTPUT_FILE="${1:-zig_monitor.csv}"

echo "Monitoring htmz process (PID: $PID) on $CPUS CPU cores"
echo "Writing to: $OUTPUT_FILE"
echo "Time,RSS(MB),PrivMem(KB),VSZ(MB),CPU%,CPU%Norm,LoadAvg" | tee "$OUTPUT_FILE"

while kill -0 $PID 2>/dev/null; do
    TIME=$(date +"%H:%M:%S")
    LOAD=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{gsub(/ /, "", $1); print $1}')

    # Get RSS and VSZ from ps (for compatibility)
    PS_DATA=$(ps -p $PID -o pcpu,rss,vsz | tail -n 1)

    # Get private memory from top (more accurate for heap tracking)
    # Use timeout to prevent top from hanging
    PRIV_MEM=$(timeout 10s top -pid $PID -l 1 -stats pid,mem 2>/dev/null | tail -n 1 | awk '{print $2}' | sed 's/[^0-9]//g')

    # If top fails, fall back to 0
    PRIV_MEM=${PRIV_MEM:-0}

    # Combine the data
    echo "$PS_DATA" | awk -v time="$TIME" -v cpus="$CPUS" -v load="$LOAD" -v priv="$PRIV_MEM" '{
        printf "%s,%.1f,%s,%.1f,%.1f,%.1f,%s\n", time, $2/1024, priv, $3/1024, $1, $1/cpus*100, load
    }' | tee -a "$OUTPUT_FILE"

    sleep 5
done

echo "Process $PID has terminated" | tee -a "$OUTPUT_FILE"
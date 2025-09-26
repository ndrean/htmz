#!/bin/bash

# Monitor Phoenix process inside Docker container
CONTAINER_NAME="${1:-htmz_phx}"

if [ -z "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
    echo "Docker container '$CONTAINER_NAME' not found or not running"
    echo "Usage: $0 [container_name]"
    exit 1
fi

# Output file (default to phoenix_docker_monitor.csv)
OUTPUT_FILE="${2:-phoenix_docker_monitor.csv}"

echo "Monitoring Phoenix in Docker container: $CONTAINER_NAME"
echo "Writing to: $OUTPUT_FILE"
echo "Time,RSS(MB),VSZ(MB),CPU%,CPU%Norm,LoadAvg,ContainerCPU%" | tee "$OUTPUT_FILE"

# Get container stats and process stats
while docker ps -q -f name=$CONTAINER_NAME > /dev/null 2>&1; do
    TIME=$(date +"%H:%M:%S")

    # Get process stats from inside container
    PROCESS_STATS=$(docker exec $CONTAINER_NAME sh -c '
        PID=$(pgrep -f "beam.smp\|mix phx.server" | head -1)
        if [ -n "$PID" ]; then
            CPUS=$(nproc 2>/dev/null || echo "1")
            LOAD=$(uptime | awk -F"load average:" "{print \$2}" | awk -F"," "{gsub(/ /, \"\", \$1); print \$1}")
            ps -p $PID -o rss=,vsz=,pcpu= | awk -v cpus="$CPUS" -v load="$LOAD" "{printf \"%.1f,%.1f,%.1f,%.1f,%s\", \$1/1024, \$2/1024, \$3, \$3/cpus*100, load}"
        else
            echo "0,0,0,0,0"
        fi
    ' 2>/dev/null)

    # Get container CPU usage
    CONTAINER_CPU=$(docker stats $CONTAINER_NAME --no-stream --format "{{.CPUPerc}}" | sed 's/%//')

    if [ -n "$PROCESS_STATS" ]; then
        echo "$TIME,$PROCESS_STATS,$CONTAINER_CPU" | tee -a "$OUTPUT_FILE"
    fi

    sleep 5
done

echo "Container $CONTAINER_NAME has stopped" | tee -a "$OUTPUT_FILE"
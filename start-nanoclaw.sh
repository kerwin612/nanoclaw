#!/bin/bash
# NanoClaw startup script for WSL
# This script starts NanoClaw in the background with nohup

cd "$(dirname "$0")"

# Kill any existing NanoClaw process
pkill -f "node.*nanoclaw" 2>/dev/null
pkill -f "tsx.*index.ts" 2>/dev/null
sleep 1

# Start NanoClaw in background
nohup npm run dev >> logs/nanoclaw.log 2>&1 &
PID=$!

echo "NanoClaw started with PID: $PID"
echo "Logs: logs/nanoclaw.log"
echo ""
echo "To view logs: tail -f logs/nanoclaw.log"
echo "To stop: pkill -f 'tsx.*index.ts'"

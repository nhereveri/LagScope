#!/usr/bin/env bash
set -uo pipefail

PORT=3724
CYCLES="${CYCLES:-50}"
OUTDIR="${OUTDIR:-.}"

MTR="$(command -v mtr || true)"
[ -z "$MTR" ] && [ -x /opt/homebrew/sbin/mtr ] && MTR=/opt/homebrew/sbin/mtr
[ -z "$MTR" ] && [ -x /usr/sbin/mtr ] && MTR=/usr/sbin/mtr

if [ -z "$MTR" ]; then
    echo "mtr not found."
    echo "  macOS:         brew install mtr"
    echo "  Debian/Ubuntu: sudo apt install mtr-tiny"
    exit 1
fi

if ! command -v lsof >/dev/null 2>&1; then
    echo "lsof not found."
    exit 1
fi

ips=$(lsof -nP -i "TCP:$PORT" 2>/dev/null \
    | awk '/ESTABLISHED/ { n = split($9, a, "->"); if (n == 2) { split(a[2], b, ":"); print b[1] } }' \
    | sort -u)

if [ -z "$ips" ]; then
    echo "No game connections found on port $PORT."
    echo "Start the client, log in to a character, and run this again."
    exit 1
fi

stamp=$(date "+%Y-%m-%dT%H:%M:%S%z")

echo "Connected game servers at $stamp:"
echo "$ips" | sed 's/^/  /'
echo
echo "Sending $CYCLES TCP probes to each in parallel (about $CYCLES seconds)."
echo "mtr needs root, so sudo will ask for your password once."
echo

sudo -v || exit 1

pids=()
for ip in $ips; do
    {
        echo "Start: $stamp"
        sudo "$MTR" -T -P "$PORT" -c "$CYCLES" --report "$ip"
    } > "$OUTDIR/$ip.log" 2>&1 &
    pids+=($!)
done
wait "${pids[@]}"

echo "Destination row of each report (this is the only row that proves anything):"
echo
for ip in $ips; do
    printf '  %s\n' "$(grep -- "$ip" "$OUTDIR/$ip.log" | tail -1)"
done
echo
echo "Full reports:"
for ip in $ips; do
    echo "  $OUTDIR/$ip.log"
done

#!/usr/bin/env bash
# Exercises the real path: curl -> Kong (key-auth) -> API -> Postgres -> SQS -> consumer -> audit table.
# Kong's host port is 8800 (port 8000 is commonly taken, e.g. by Splunk). Override with KONG_PORT or GW.
set -euo pipefail
GW=${GW:-http://localhost:${KONG_PORT:-8800}}
KEY=${KEY:-dev-web-key}
need() { command -v "$1" >/dev/null || { echo "missing $1"; exit 1; }; }
need curl; need jq

echo "0. wait for gateway at $GW"
for i in $(seq 1 60); do curl -s -o /dev/null "$GW/api/health" && break; sleep 2; done

echo "1. gateway rejects calls without a key"
code=$(curl -s -o /dev/null -w '%{http_code}' "$GW/api/portfolios")
if [ "$code" != "401" ]; then
  echo "expected 401, got $code"
  echo "hint: if this is a 3xx or the Server header is not Kong, another program owns that port:"
  echo "      curl -i $GW/api/portfolios | head; ss -ltnp | grep ':${GW##*:} '"
  exit 1
fi

echo "2. wait for API behind the gateway"
for i in $(seq 1 60); do
  curl -sf -H "apikey: $KEY" "$GW/api/health" >/dev/null && break
  sleep 2
  [ "$i" = 60 ] && { echo "API never became healthy"; exit 1; }
done

echo "3. list portfolios"
ID=$(curl -sf -H "apikey: $KEY" "$GW/api/portfolios" | jq -r '.[0].id')
[ -n "$ID" ] && echo "   first portfolio: $ID"

echo "4. place a trade"
curl -sf -H "apikey: $KEY" -H 'Content-Type: application/json' \
  -d '{"symbol":"SGOV","side":"Buy","quantity":5}' "$GW/api/portfolios/$ID/trades" | jq -c '{symbol,side,quantity,price}'

echo "5. rejected trade returns 422"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "apikey: $KEY" -H 'Content-Type: application/json' \
  -d '{"symbol":"VTI","side":"Buy","quantity":99999999}' "$GW/api/portfolios/$ID/trades")
[ "$code" = "422" ] || { echo "expected 422, got $code"; exit 1; }

echo "6. trade event reaches the audit log via the queue"
for i in $(seq 1 20); do
  n=$(curl -sf -H "apikey: $KEY" "$GW/api/audit" | jq 'length')
  [ "$n" -ge 1 ] && { echo "   audit entries: $n"; echo "OK"; exit 0; }
  sleep 1
done
echo "no audit entry appeared"; exit 1

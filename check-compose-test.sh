#!/usr/bin/env bash
set -Eeuo pipefail

workspace_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
compose=(docker compose -f "$workspace_dir/compose.yml" -f "$workspace_dir/compose-test.yml")
prometheus_url="http://localhost:9090"
start_wait_seconds=120
metrics_wait_seconds=90
logs_wait_seconds=90
traces_wait_seconds=90
poll_interval_seconds=5
log_query_image="python:3.14-alpine"
metrics_query='{__name__=~"up|mysql_up|nginx_connections_active|redis_up|node_load1"}'
trace_services=(mysql mysql-exporter nginx nginx-exporter redis redis-exporter node-exporter)

if ! command -v docker >/dev/null 2>&1; then
    printf 'Docker is required but was not found in PATH.\n' >&2
    exit 1
fi

if ! docker image inspect "$log_query_image" >/dev/null 2>&1; then
    printf 'Pulling temporary log-query image %s...\n' "$log_query_image"
    if ! docker pull "$log_query_image"; then
        printf 'Could not pull the temporary log-query image.\n' >&2
        exit 1
    fi
fi

printf 'Starting services...\n'
if ! "${compose[@]}" up -d --wait --wait-timeout "$start_wait_seconds"; then
    printf 'One or more services failed to start. Current status and logs:\n' >&2
    "${compose[@]}" ps -a >&2 || true
    "${compose[@]}" logs --no-color --tail=80 >&2 || true
    exit 1
fi

printf 'Waiting for metrics to reach Prometheus...\n'
deadline=$((SECONDS + metrics_wait_seconds))
missing=("Prometheus query has not returned data")
result=''

while (( SECONDS <= deadline )); do
    if result="$("${compose[@]}" exec -T prometheus promtool query instant "$prometheus_url" "$metrics_query" 2>/dev/null)"; then
        missing=()

        for job in mysql nginx redis node; do
            if ! grep -Eq "^up\\{[^}]*job=\"$job\"[^}]*\\} => 1([[:space:]]|$)" <<<"$result"; then
                missing+=("up{job=\"$job\"}=1")
            fi
        done

        for metric in mysql_up nginx_connections_active redis_up node_load1; do
            if ! grep -Eq "^${metric}\\{" <<<"$result"; then
                missing+=("$metric")
            fi
        done

        if (( ${#missing[@]} == 0 )); then
            printf 'All expected metrics reached Prometheus:\n%s\n' "$result"
            break
        fi
    fi

    sleep "$poll_interval_seconds"
done

if (( ${#missing[@]} > 0 )); then
    printf 'Timed out after %s seconds waiting for metrics. Missing: %s\n' \
        "$metrics_wait_seconds" "${missing[*]}" >&2
    if [[ -n "$result" ]]; then
        printf 'Last Prometheus query result:\n%s\n' "$result" >&2
    fi
    "${compose[@]}" logs --no-color --tail=80 otelcol prometheus mysql-exporter nginx-exporter redis-exporter node-exporter >&2 || true
    exit 1
fi

log_marker="compose-test-$(date -u +%Y%m%dT%H%M%S)-${BASHPID}-${RANDOM}"
logs_start_ns="$(date +%s%N)"
printf 'Generating fresh log entries with marker %s...\n' "$log_marker"

if ! "${compose[@]}" exec -T --env MYSQL_PWD=test-root-password mysql \
    mysql --user=root --batch --skip-column-names --execute="SELECT '$log_marker';" >/dev/null; then
    printf 'Failed to write the test query to the MySQL general log.\n' >&2
    "${compose[@]}" logs --no-color --tail=80 mysql otelcol >&2 || true
    exit 1
fi

if ! redis_result="$("${compose[@]}" exec -T redis redis-cli --raw \
    EVAL "redis.log(redis.LOG_NOTICE, ARGV[1]); return 1" 0 "$log_marker" 2>&1)"; then
    printf 'Failed to write the test marker to the Redis log.\n%s\n' "$redis_result" >&2
    "${compose[@]}" logs --no-color --tail=80 redis otelcol >&2 || true
    exit 1
elif [[ "$redis_result" != "1" ]]; then
    printf 'Redis did not confirm the test log command. Response: %s\n' "$redis_result" >&2
    exit 1
fi

nginx_container_id="$("${compose[@]}" ps -q nginx)"
if [[ -z "$nginx_container_id" ]]; then
    printf 'Could not find the nginx container for the log test.\n' >&2
    exit 1
fi

if ! docker run --rm -i --network "container:$nginx_container_id" \
    --entrypoint python "$log_query_image" - "$log_marker" <<'PY'
import sys
from urllib.parse import quote
from urllib.request import urlopen

marker = sys.argv[1]
url = "http://127.0.0.1/?compose_test_run=" + quote(marker, safe="")
with urlopen(url, timeout=5) as response:
    if response.status != 200:
        raise SystemExit("nginx returned HTTP {}".format(response.status))
    response.read()
PY
then
    printf 'Failed to write the test marker to the nginx access log.\n' >&2
    "${compose[@]}" logs --no-color --tail=80 nginx otelcol >&2 || true
    exit 1
fi

loki_container_id="$("${compose[@]}" ps -q loki)"
if [[ -z "$loki_container_id" ]]; then
    printf 'Could not find the Loki container for the log test.\n' >&2
    exit 1
fi

printf 'Waiting for fresh service logs to reach Loki...\n'
deadline=$((SECONDS + logs_wait_seconds))
missing_logs=(mysql nginx redis)
last_loki_result='Loki query has not returned data'

while (( SECONDS <= deadline )); do
    if last_loki_result="$(docker run --rm -i --network "container:$loki_container_id" \
        --entrypoint python "$log_query_image" - "$log_marker" "$logs_start_ns" 2>&1 <<'PY'
import json
import sys
import time
from urllib.parse import urlencode
from urllib.request import urlopen

marker = sys.argv[1]
start_ns = sys.argv[2]
expected = {"mysql", "nginx", "redis"}
query = '{service_name=~"mysql|nginx|redis"} |= "' + marker + '"'
params = urlencode({
    "query": query,
    "start": start_ns,
    "end": str(time.time_ns()),
    "limit": "100",
})
url = "http://127.0.0.1:3100/loki/api/v1/query_range?" + params

try:
    with urlopen(url, timeout=5) as response:
        payload = json.load(response)
    if payload.get("status") != "success":
        raise ValueError("Loki returned status {!r}".format(payload.get("status")))
    data = payload.get("data")
    if not isinstance(data, dict) or data.get("resultType") != "streams":
        raise ValueError("Loki response did not contain log streams")
    streams = data.get("result")
    if not isinstance(streams, list):
        raise ValueError("Loki response contained an invalid stream list")

    found = set()
    for stream in streams:
        if not isinstance(stream, dict):
            continue
        service = stream.get("stream", {}).get("service_name")
        if service not in expected:
            continue
        for entry in stream.get("values", []):
            if isinstance(entry, list) and len(entry) >= 2 and marker in str(entry[1]):
                found.add(service)

    missing = sorted(expected - found)
    print("missing=" + ",".join(missing))
    sys.exit(1 if missing else 0)
except Exception as error:
    print("Loki query failed: {}: {}".format(type(error).__name__, error), file=sys.stderr)
    sys.exit(2)
PY
    )"; then
        missing_logs=()
        break
    fi

    if [[ "$last_loki_result" == missing=* ]]; then
        missing_text="${last_loki_result#missing=}"
        if [[ -n "$missing_text" ]]; then
            IFS=',' read -r -a missing_logs <<< "$missing_text"
        else
            missing_logs=()
        fi
    fi
    sleep "$poll_interval_seconds"
done

if (( ${#missing_logs[@]} > 0 )); then
    printf 'Timed out after %s seconds waiting for logs in Loki. Missing: %s\n' \
        "$logs_wait_seconds" "${missing_logs[*]}" >&2
    printf 'Last Loki query result:\n%s\n' "$last_loki_result" >&2
    "${compose[@]}" logs --no-color --tail=80 otelcol alloy loki mysql nginx redis >&2 || true
    printf 'Last lines from the service log files:\n' >&2
    "${compose[@]}" exec -T mysql sh -c \
        'for file in /var/log/mysql/general.log /var/log/mysql/error.log; do if [ -f "$file" ]; then tail -n 10 "$file"; else printf "missing: %s\n" "$file"; fi; done' >&2 || true
    "${compose[@]}" exec -T nginx sh -c \
        'for file in /var/log/nginx/test-access.log /var/log/nginx/test-error.log; do if [ -f "$file" ]; then tail -n 10 "$file"; else printf "missing: %s\n" "$file"; fi; done' >&2 || true
    "${compose[@]}" exec -T redis sh -c \
        'if [ -f /data/redis.log ]; then tail -n 10 /data/redis.log; else printf "missing: /data/redis.log\n"; fi' >&2 || true
    exit 1
fi

printf 'All expected service logs reached Loki.\n'

trace_marker="compose-test-trace-$(date -u +%Y%m%dT%H%M%S)-${BASHPID}-${RANDOM}"
otelcol_container_id="$("${compose[@]}" ps -q otelcol)"
if [[ -z "$otelcol_container_id" ]]; then
    printf 'Could not find the OpenTelemetry Collector container for the trace test.\n' >&2
    exit 1
fi

printf 'Sending test traces for %s through the OpenTelemetry Collector...\n' "${trace_services[*]}"
if ! docker run --rm -i --network "container:$otelcol_container_id" \
    --entrypoint python "$log_query_image" - "$trace_marker" "${trace_services[@]}" <<'PY'
import hashlib
import json
import sys
import time
from urllib.request import Request, urlopen

marker = sys.argv[1]
services = sys.argv[2:]
resource_spans = []
trace_ids = {}

for service in services:
    trace_id = hashlib.sha256((marker + ":" + service).encode()).hexdigest()[:32]
    span_id = hashlib.sha256((marker + ":" + service + ":span").encode()).hexdigest()[:16]
    end_time_ns = time.time_ns()
    trace_ids[service] = trace_id
    resource_spans.append({
        "resource": {
            "attributes": [
                {"key": "service.name", "value": {"stringValue": service}},
                {"key": "compose.test.run", "value": {"stringValue": marker}},
            ],
        },
        "scopeSpans": [{
            "scope": {"name": "compose-test"},
            "spans": [{
                "traceId": trace_id,
                "spanId": span_id,
                "name": "compose-test " + service,
                "kind": "SPAN_KIND_INTERNAL",
                "startTimeUnixNano": str(end_time_ns - 1_000_000),
                "endTimeUnixNano": str(end_time_ns),
                "attributes": [
                    {"key": "compose.test.run", "value": {"stringValue": marker}},
                ],
            }],
        }],
    })

request = Request(
    "http://127.0.0.1:4318/v1/traces",
    data=json.dumps({"resourceSpans": resource_spans}).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urlopen(request, timeout=10) as response:
    if response.status != 200:
        raise SystemExit("OTLP trace export returned HTTP {}".format(response.status))
print("Submitted {} service traces.".format(len(trace_ids)))
PY
then
    printf 'Failed to send test traces to the OpenTelemetry Collector.\n' >&2
    "${compose[@]}" logs --no-color --tail=80 otelcol alloy tempo >&2 || true
    exit 1
fi

tempo_container_id="$("${compose[@]}" ps -q tempo)"
if [[ -z "$tempo_container_id" ]]; then
    printf 'Could not find the Tempo container for the trace test.\n' >&2
    exit 1
fi

printf 'Waiting for service traces to reach Tempo...\n'
deadline=$((SECONDS + traces_wait_seconds))
missing_traces=("${trace_services[@]}")
last_tempo_result='Tempo trace lookup has not returned data'

while (( SECONDS <= deadline )); do
    if last_tempo_result="$(docker run --rm -i --network "container:$tempo_container_id" \
        --entrypoint python "$log_query_image" - "$trace_marker" "${trace_services[@]}" 2>&1 <<'PY'
import hashlib
import json
import sys
from urllib.request import urlopen

marker = sys.argv[1]
services = sys.argv[2:]
missing = []

for service in services:
    trace_id = hashlib.sha256((marker + ":" + service).encode()).hexdigest()[:32]
    try:
        with urlopen("http://127.0.0.1:3200/api/traces/" + trace_id, timeout=5) as response:
            trace = json.load(response)
        serialized = json.dumps(trace, sort_keys=True)
        if marker not in serialized or service not in serialized:
            missing.append(service)
    except Exception:
        missing.append(service)

print("missing=" + ",".join(missing))
sys.exit(1 if missing else 0)
PY
    )"; then
        missing_traces=()
        break
    fi

    if [[ "$last_tempo_result" == missing=* ]]; then
        missing_text="${last_tempo_result#missing=}"
        if [[ -n "$missing_text" ]]; then
            IFS=',' read -r -a missing_traces <<< "$missing_text"
        else
            missing_traces=()
        fi
    fi
    sleep "$poll_interval_seconds"
done

if (( ${#missing_traces[@]} > 0 )); then
    printf 'Timed out after %s seconds waiting for traces in Tempo. Missing: %s\n' \
        "$traces_wait_seconds" "${missing_traces[*]}" >&2
    printf 'Last Tempo query result:\n%s\n' "$last_tempo_result" >&2
    "${compose[@]}" logs --no-color --tail=80 otelcol alloy tempo >&2 || true
    exit 1
fi

printf 'All expected service traces reached Tempo.\n'
printf 'Services remain running.\n'
#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
installer="$root/scripts/install-meshcore-observer.sh"
bash -n "$installer"
bash "$installer" --self-test
plan=$(bash "$installer" --dry-run --iata LOC --port /dev/serial/by-id/mock)
grep -Fq 'Plan only' <<<"$plan"
grep -Fq 'no prompts, downloads, writes, services, or checks' <<<"$plan"
echo 'Installer static/mocked tests passed.'


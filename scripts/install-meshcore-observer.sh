#!/usr/bin/env bash
# Native Raspberry Pi observer installer. It never flashes radio firmware.
set -Eeuo pipefail
IFS=$'\n\t'

readonly APP='MeshCore Raspberry Pi Observer'
readonly SERVICE='meshcore-packet-capture.service'
readonly ETC_DIR='/etc/meshcore-packet-capture'
readonly OWNED_CONFIG="$ETC_DIR/config.d/99-z-local-observer.toml"
readonly MOSQUITTO_DROPIN='/etc/mosquitto/conf.d/99-local-observer.conf'
readonly CAPTURE_TAG='v2.2.0'
readonly CAPTURE_SHA256='38173cb9b3e5eefb2978a63465aff595be754c53aa374697b8049d2e3c2b0056'
readonly MESHLIB_VERSION='2.3.16'
readonly CAPTURE_URL="https://github.com/agessaman/meshcore-packet-capture/archive/refs/tags/${CAPTURE_TAG}.tar.gz"

DRY_RUN=false; REPAIR=false; SELECTED_PORT=''; IATA=''
WORK=''
say() { printf '\n==> %s\n' "$*"; }
ok() { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!] %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -n "$WORK" && -d "$WORK" ]] && rm -rf -- "$WORK"; }
trap cleanup EXIT
trap 'die "Stopped at line $LINENO; no radio firmware was changed."' ERR

usage() { cat <<'EOF'
Usage: sudo bash scripts/install-meshcore-observer.sh [options]

  --port PATH       Companion path in /dev/serial/by-id
  --iata CODE       Region code (3-8 uppercase letters/digits; default: LOC)
  --repair          Reinstall/update the pinned capture release and refresh owned files
  --dry-run         Print the plan only: no prompts, downloads, writes, services, or checks
  --self-test       Run offline parser/config tests
  -h, --help        Show this help
EOF
}
while (($#)); do case "$1" in
  --port) SELECTED_PORT=${2:?missing port}; shift 2;;
  --iata) IATA=${2:?missing IATA}; shift 2;;
  --repair) REPAIR=true; shift;; --dry-run) DRY_RUN=true; shift;;
  --self-test) SELF_TEST=true; shift;; -h|--help) usage; exit 0;; *) die "Unknown option: $1";;
esac; done

valid_iata() { [[ $1 =~ ^[A-Z0-9]{3,8}$ ]]; }
check() { local label=$1; shift; if "$@"; then ok "$label"; else printf '  [x] %s\n' "$label" >&2; return 1; fi; }
run() { "$@"; }

plan() {
  cat <<EOF
Plan only (nothing will be inspected or changed):
  * require Raspberry Pi OS/Debian, systemd, sudo/root, Python 3.11+, curl and USB serial
  * select a /dev/serial/by-id Companion and perform a read-only MeshCore device query
  * install signed distribution packages mosquitto and mosquitto-clients
  * download ${CAPTURE_TAG}, verify SHA-256, and use its native systemd installer
  * write only $OWNED_CONFIG and $MOSQUITTO_DROPIN
  * enable/restart services and report current-invocation health
  * never configure an external broker or modify radio firmware
EOF
}
is_supported_host() {
  [[ -r /etc/os-release && -r /proc/device-tree/model ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == raspbian || ${ID:-} == debian || " ${ID_LIKE:-} " == *' debian '* ]] && grep -qi 'raspberry pi' /proc/device-tree/model
}
preflight() {
  is_supported_host || die 'Supported only on Raspberry Pi OS / Debian-based Raspberry Pi hosts.'
  [[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"
  for c in systemctl apt-get curl sha256sum python3 readlink; do command -v "$c" >/dev/null || die "Missing required command: $c"; done
  systemctl --version >/dev/null || die 'systemd is not available.'
  python3 - <<'PY' || die 'Python 3.11 or newer is required.'
import sys
raise SystemExit(sys.version_info < (3, 11))
PY
  python3 -m venv --help >/dev/null || die 'Python venv support is required for the read-only Companion probe.'
  ok 'Raspberry Pi, Debian-family OS, systemd, sudo, Python, curl, and serial prerequisites'
}
serial_candidates() { find /dev/serial/by-id -maxdepth 1 -type l -print 2>/dev/null | sort; }
choose_port() {
  if [[ -n $SELECTED_PORT ]]; then [[ $SELECTED_PORT == /dev/serial/by-id/* && -e $SELECTED_PORT ]] || die '--port must be an existing /dev/serial/by-id path.'; return; fi
  mapfile -t ports < <(serial_candidates); ((${#ports[@]})) || die 'No USB serial device found under /dev/serial/by-id.'
  if ((${#ports[@]} == 1)); then SELECTED_PORT=${ports[0]}; else
    printf 'Select the regular MeshCore Companion USB device:\n'; select SELECTED_PORT in "${ports[@]}"; do [[ -n $SELECTED_PORT ]] && break; done
  fi
  ok "Selected stable serial path: $SELECTED_PORT"
}

# Runs in a disposable directory before system packages/configuration are changed.
# It only asks the Companion protocol for self/device information; it sends no write command.
probe_companion() {
  say 'Validating Companion protocol (read-only)'
  WORK=$(mktemp -d); python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" --disable-pip-version-check install --quiet "meshcore==${MESHLIB_VERSION}"
  "$WORK/venv/bin/python" - "$SELECTED_PORT" <<'PY'
import asyncio, sys
from meshcore import MeshCore, EventType

async def main(port):
    radio = await MeshCore.create_serial(port, 115200)
    try:
        self_info = await radio.commands.send_appstart()
        device = await radio.commands.send_device_query()
        if self_info.type == EventType.ERROR or device.type == EventType.ERROR:
            raise RuntimeError('the device rejected a Companion protocol query')
        payload = device.payload or {}
        model = str(payload.get('model', '')).strip()
        version = str(payload.get('version', '')).strip()
        identity = (self_info.payload or {}).get('public_key') or (self_info.payload or {}).get('publicKey')
        if not model or not version or not identity:
            raise RuntimeError('no model, firmware version, and public key were returned')
        print(f'Companion model: {model}')
        print(f'Firmware: {version}')
        print(f'Public key: {identity}')
    finally:
        close = getattr(radio, 'close', None)
        if close:
            result = close()
            if hasattr(result, '__await__'): await result
asyncio.run(main(sys.argv[1]))
PY
  ok 'Companion protocol validation passed'
}
install_mosquitto() {
  say 'Installing local Mosquitto broker from signed distribution packages'
  apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y mosquitto mosquitto-clients
  systemctl enable mosquitto.service
}
install_capture() {
  say "Installing pinned meshcore-packet-capture ${CAPTURE_TAG}"
  mkdir -p "$WORK/capture"; curl --fail --location --proto '=https' --tlsv1.2 --output "$WORK/capture.tar.gz" "$CAPTURE_URL"
  printf '%s  %s\n' "$CAPTURE_SHA256" "$WORK/capture.tar.gz" | sha256sum --check --status || die 'Pinned archive checksum mismatch.'
  tar -xzf "$WORK/capture.tar.gz" -C "$WORK/capture" --strip-components=1
  # The upstream managed installer is interactive on first install. It provides
  # the service account/unit. Choose serial and the selected by-id path; do not add an external broker.
  if [[ -d /opt/meshcore-packet-capture && $REPAIR == true ]]; then
    (cd "$WORK/capture" && LOCAL_INSTALL="$WORK/capture" python3 -m installer --tag "$CAPTURE_TAG" update)
  elif [[ ! -d /opt/meshcore-packet-capture ]]; then
    (cd "$WORK/capture" && LOCAL_INSTALL="$WORK/capture" python3 -m installer --tag "$CAPTURE_TAG" install)
  else
    ok 'Pinned capture installation already present (use --repair to update)'
  fi
}
service_identity() { systemctl show -p User --value "$SERVICE" 2>/dev/null || true; }
write_owned_files() {
  say 'Writing narrowly-scoped local integration configuration'
  IATA=${IATA:-LOC}; IATA=${IATA^^}; valid_iata "$IATA" || die 'IATA must be 3-8 uppercase letters/digits.'
  local user group temp; user=$(service_identity); user=${user:-meshcore-capture}; group=$(id -gn "$user" 2>/dev/null || printf '%s' "$user")
  install -d -m 0750 -o root -g "$group" "$ETC_DIR/config.d"
  if [[ -e $OWNED_CONFIG ]]; then cp -a -- "$OWNED_CONFIG" "${OWNED_CONFIG}.bak.$(date -u +%Y%m%dT%H%M%SZ)"; fi
  temp=$(mktemp); cat >"$temp" <<EOF
# Managed by MeshCore Raspberry Pi Observer. This file intentionally does not
# alter upstream/user 99-user.toml. Sorted load order makes this final override.
[general]
iata = "$IATA"

[serial]
ports = ["$SELECTED_PORT"]
baud_rate = 115200
timeout = 2

[capture]
connection_type = "serial"

[[broker]]
name = "local-mosquitto"
enabled = true
server = "127.0.0.1"
port = 1883
transport = "tcp"
qos = 0
retain = true
EOF
  install -m 0640 -o root -g "$group" "$temp" "$OWNED_CONFIG"; rm -f -- "$temp"
  install -d -m 0755 -o root -g root /etc/mosquitto/conf.d
  if [[ -e $MOSQUITTO_DROPIN ]]; then cp -a -- "$MOSQUITTO_DROPIN" "${MOSQUITTO_DROPIN}.bak.$(date -u +%Y%m%dT%H%M%SZ)"; fi
  cat >"$MOSQUITTO_DROPIN" <<'EOF'
# Managed local-only listener. No remote listener, credentials, or bridge.
listener 1883 127.0.0.1
allow_anonymous true
EOF
  chmod 0644 "$MOSQUITTO_DROPIN"
  local serial_group; serial_group=$(stat -c '%G' "$SELECTED_PORT")
  usermod -aG "$serial_group" "$user"
  ok 'Local serial and loopback MQTT configuration written'
}
validate_mosquitto() { mosquitto -c /etc/mosquitto/mosquitto.conf -t >/dev/null; }
restart_and_verify() {
  local since failures=0; since=$(date --iso-8601=seconds)
  systemctl daemon-reload; validate_mosquitto
  systemctl restart mosquitto.service
  systemctl enable "$SERVICE"; systemctl restart "$SERVICE"
  sleep 5
  say 'Current-invocation verification'
  check 'Mosquitto is active' systemctl is-active --quiet mosquitto.service || failures=$((failures+1))
  check 'Capture service is active' systemctl is-active --quiet "$SERVICE" || failures=$((failures+1))
  check 'Owned serial configuration is present' grep -Fq "$SELECTED_PORT" "$OWNED_CONFIG" || failures=$((failures+1))
  check 'Local MQTT broker accepts publish/subscribe' bash -c '
    mosquitto_sub -h 127.0.0.1 -t observer-health -C 1 >/dev/null &
    pid=$!; sleep 0.2; mosquitto_pub -h 127.0.0.1 -t observer-health -m ok; wait "$pid"
  ' || failures=$((failures+1))
  if timeout 3 mosquitto_sub -h 127.0.0.1 -t 'meshcore/+/+/status' -C 1 >/dev/null; then
    ok 'Capture status is available on local MQTT'
  else
    warn 'No capture status received yet (not a configuration failure).'
  fi
  if journalctl -u "$SERVICE" --since "$since" --no-pager | grep -Eqi '(error|traceback|failed)'; then warn 'Capture service reported an error in this invocation; inspect the journal command below.'; failures=$((failures+1)); fi
  ((failures == 0)) || die "$failures configuration/service check(s) failed."
}
self_test() { valid_iata LOC && valid_iata ABC123 && ! valid_iata abc && ! valid_iata ABCDEFGHI || die 'IATA parser self-test failed'; check 'check() preserves all command arguments' test one = one; ok 'Offline self-tests passed'; }
main() {
  if [[ ${SELF_TEST:-false} == true ]]; then self_test; return; fi
  if $DRY_RUN; then plan; return; fi
  preflight; choose_port; probe_companion; install_mosquitto; install_capture; write_owned_files; restart_and_verify
  cat <<EOF

Installation completed. Reboot the Raspberry Pi when convenient; this ensures
serial-group membership, systemd services, and configuration are all reloaded.

After reboot:
  sudo systemctl status mosquitto $SERVICE
  sudo journalctl -u $SERVICE -b --no-pager
  mosquitto_sub -h 127.0.0.1 -t 'meshcore/+/+/status' -v
  mosquitto_sub -h 127.0.0.1 -t 'meshcore/+/+/packets' -v
EOF
}
main "$@"


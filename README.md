# MeshCore Raspberry Pi Observer

This is a native, systemd-managed installer for a Raspberry Pi that is connected by USB to a radio running regular MeshCore **Companion** firmware. It installs a local Eclipse Mosquitto broker and the upstream `meshcore-packet-capture` service, then publishes the observer's packet and status data to the local broker. It does not use Docker and it never flashes firmware.

## Supported setup

- Raspberry Pi OS or another Debian-based OS running on a Raspberry Pi
- systemd, `sudo`, Python 3.11+, `curl`, and a USB serial interface
- a regular MeshCore Companion radio connected by USB
- a stable `/dev/serial/by-id/...` entry for that radio

Repeaters and RoomServers are not supported. The installer sends read-only Companion protocol queries before it changes the system, and requires the radio to return a model, firmware version, and public key.

## Install

On the Raspberry Pi, run these commands:

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/buildsbyrodney/meshcore-pi-observer.git
cd meshcore-pi-observer
sudo bash scripts/install-meshcore-observer.sh --iata LOC
```

Replace `LOC` with your 3–8 character uppercase region/IATA code. The installer will find the USB Companion automatically when it is the only serial device. If more than one USB serial device is connected, specify the radio explicitly:

```bash
sudo bash scripts/install-meshcore-observer.sh \
  --iata LOC \
  --port /dev/serial/by-id/<your-companion-device>
```

Use `--dry-run` to view the plan before installing. Use `--repair` to rerun the pinned upstream capture installation and refresh only this installer's owned files.

The upstream capture installer remains interactive on its first run because it owns its system service and installation directory. Select **Serial** and the same `/dev/serial/by-id/...` device when prompted. Do not add an external broker in that upstream dialog; this installer adds the local broker integration afterward.

## What it installs and owns

- `mosquitto` and `mosquitto-clients`, installed from the Raspberry Pi OS/Debian signed package repository.
- `meshcore-packet-capture` `v2.2.0` from its upstream GitHub tag. The release archive is verified before it is run.
- `/etc/mosquitto/conf.d/99-local-observer.conf`, a loopback-only listener at `127.0.0.1:1883`.
- `/etc/meshcore-packet-capture/config.d/99-z-local-observer.toml`, which selects USB serial and adds a `local-mosquitto` broker.

The installer never replaces `99-user.toml`, upstream configuration, or user-created broker fragments. Its `99-z-` filename intentionally sorts after upstream's `99-user.toml`; broker entries merge by `name`, so the separately named local broker is additive. It only backs up files that it owns before replacing them.

The source is pinned at this project version to `meshcore-packet-capture v2.2.0`, SHA-256 `38173cb9b3e5eefb2978a63465aff595be754c53aa374697b8049d2e3c2b0056`. The disposable preflight probe pins the official `meshcore` Python package at `2.3.16`.

Mosquitto is deliberately installed through signed distribution packages instead of compiling an archive from upstream GitHub. That gives Raspberry Pi OS/Debian security updates, dependency handling, and a package-managed system service. Eclipse Mosquitto does publish signed source archives, but does not publish broker binaries through GitHub Releases; using the signed system package is the safer native deployment path. Check the installed version with `mosquitto -h` or `apt-cache policy mosquitto`.

If the upstream capture installer offers its bundled LetsMesh preset, it may be enabled without any private external credentials. This project neither creates nor changes that preset; it does not overwrite an existing preset and does not enable extra raw or debug topic publication.

## Reboot required

When the installer finishes, reboot the Pi yourself:

```bash
sudo reboot
```

The installer never reboots automatically. A reboot ensures new serial-group membership, systemd services, and all configuration are reloaded cleanly.

## Post-reboot checks

```bash
sudo systemctl status mosquitto meshcore-packet-capture
sudo journalctl -u meshcore-packet-capture -b --no-pager
mosquitto_sub -h 127.0.0.1 -t 'meshcore/+/+/status' -v
mosquitto_sub -h 127.0.0.1 -t 'meshcore/+/+/packets' -v
```

The first status payload normally identifies the radio; the preflight output also prints the detected Companion public key and firmware version. A quiet mesh may produce no packet messages immediately. That is expected and is not a service/configuration failure.

## Connect this observer to an external CoreScope/MQTT server

An external operator should provide the host, port, transport, TLS requirements, websocket path (when applicable), and credentials. Add a separate, root-owned fragment; do not edit the installer's local fragment:

```bash
sudoedit /etc/meshcore-packet-capture/config.d/99-z-external-mqtt.toml
sudo chown root:"$(systemctl show -p User --value meshcore-packet-capture)" /etc/meshcore-packet-capture/config.d/99-z-external-mqtt.toml
sudo chmod 0640 /etc/meshcore-packet-capture/config.d/99-z-external-mqtt.toml
```

Use a unique broker `name`. This generic WebSockets/TLS example uses placeholders only:

```toml
[[broker]]
name = "external-observer"
enabled = true
server = "mqtt.example.org"
port = 443
transport = "websockets"       # use "tcp" for normal MQTT/TLS
websocket_path = "/mqtt"       # omit for tcp or when the operator does not require one
qos = 0
retain = true

[broker.tls]
enabled = true
verify = true

[broker.auth]
method = "password"
username = "<username>"
password = "<password>"

# Optional only when the operator explicitly requires different topics:
# [broker.topics]
# status = "meshcore/{IATA}/{PUBLIC_KEY}/status"
# packets = "meshcore/{IATA}/{PUBLIC_KEY}/packets"
```

For a plain TCP service, set `transport = "tcp"`; set `port` and TLS exactly as supplied by the operator. Keep `verify = true` unless the operator has a documented certificate trust procedure. Never put the password in a world-readable file.

The normal templates are:

```text
meshcore/{IATA}/{PUBLIC_KEY}/status
meshcore/{IATA}/{PUBLIC_KEY}/packets
```

An operator may restrict an account to `meshcore/<IATA>/<PUBLIC_KEY>/#`. You normally do not enter that ACL scope in this file—only use per-broker topic overrides when their software explicitly requires them.

Apply changes and watch the connection:

```bash
sudo systemctl restart meshcore-packet-capture
sudo journalctl -u meshcore-packet-capture -f
```

Look for the named broker connecting/authenticating. A successful broker connection does not guarantee RF traffic; packet messages appear only when the Companion hears them.

## Validation and limitations

Run the repository checks on a development machine:

```bash
bash -n scripts/install-meshcore-observer.sh
bash tests/test-installer.sh
shellcheck scripts/install-meshcore-observer.sh tests/test-installer.sh
```

The mocked tests cover syntax, the argument-preserving `check` helper, dry-run behavior, and IATA validation. Hardware, package installation, serial probing, service restarts, and upstream installer interactions must be validated on a disposable Pi before release; they are intentionally not run by these tests.

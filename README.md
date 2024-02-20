# `sysmon-mqtt` — Simple system monitoring over MQTT

A simple shell-script to capture a handful of common metrics and push them over
MQTT to [Home Assistant](https://www.home-assistant.io/).

This script has been tested on recent versions of various Linux distributions
(Ubuntu, Raspberry Pi OS, Armbian, Alpine, and DD-WRT) on AMD64, ARM(64) and
RISC-V based devices. Given its relative simplicity, it probably works on
virtually any Linux device that allows installing a handful of (generic)
dependencies.

Until December 2023, this script was part of my
[Home Assistant configuration](https://github.com/thijsputman/home-assistant-config/tree/2ec7d637e642196f45a04fa0f99c0eeee4daba9d/extras/sysmon-mqtt)-repository
– release history prior to that point is preserved in
[`📄 HISTORY.md`](./HISTORY.md).

- [Metrics](#metrics)
  - [Heartbeat](#heartbeat)
  - [Home Assistant discovery](#home-assistant-discovery)
  - [APT-check](#apt-check)
- [Setup](#setup)
  - [Broker](#broker)
- [Usage](#usage)
  - [Daemon-mode](#daemon-mode)
  - [Docker](#docker)
  - [`systemd`](#systemd)

## Metrics

Currently, the following metrics are provided:

- `cpu_load` — the 1-minute load as a percentage of maximum nominal load (e.g.
  for a quad-core system, 100% represents a 1-minute load of 4.0)
- `cpu_temp` — CPU temperature in degrees Celsius (read from
  `/sys/class/thermal/thermal_zone0/temp` – omitted if not available)
- `mem_used` — memory in use (_excluding_ buffers and caches) as a percentage of
  total available memory
- `uptime` — uptime in seconds
- `status` – overall status of the system (systemd-only;
  [as reported by `systemctl is-system-running`](https://www.freedesktop.org/software/systemd/man/systemctl.html#is-system-running))
- `bandwidth` — average bandwidth (receive and transmit) for individual network
  adapters in kbps during the monitoring interval
  - For wireless adapaters, signal-strength is also reported (detection based on
    adapter name matching the `wl*`-pattern; requires `iw`-binary)
- `rtt` – average round-trip (ie, ping) times in ms to one or more hosts
- `apt` — number of APT packages that can upgraded
  - This assumes a Debian(-derived) distribution; the APT-related metrics are
    automatically disabled when no `apt`-binary is present
- `reboot_required` — Reports `1` if a system reboot is required as a result of
  APT package upgrades

The metrics are provided as a JSON-object in the `sysmon/[device-name]/state`
topic.

Additionally, the version of the running `sysmon-mqtt`-script is provided in
`sysmon/[device-name]/version`.

### Heartbeat

A persistent `sysmon/[device-name]/connected` topic is provided as an indication
of whether the script is active. Its value works as a "heartbeat": It contains
the Unix timestamp of the most recent reporting iteration, `-1` while the script
is initialising, and `0` if the script was gracefully shutdown.

In case a stale timestamp is present, it may be assumed the script (or the
machine its running on) has crashed / dropped from the network. Stale is best
defined as three times the reporting interval. For the default configuration
that would amount to 90 seconds.

When the script starts, a heartbeat of `-1` is reported until the script's
_second_ iteration; this is done because some of the metrics (`bandwidth`, `rtt`
and `apt`) are – due to various technical reasons – only reported from the
second iteration onwards...

### Home Assistant discovery

By default, the script publishes
[Home Assistant discovery](https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery)
messages to the `homeassistant/sensors/sysmon` topic.

These messages are retained. Any new instance of the script started with an
already present `device-name` will re-use the existing sensor-entity `unique_id`
values (and thus "adopt" the previous instance's sensors in Home Assistant).
This behaviour is intended to allow "fixed" sensor-entities in Home Assistant
(which can easily be customised via the GUI).

The `apt`-metric is presented as a Home Assistant
[Update-entity](https://www.home-assistant.io/integrations/update.mqtt/). For
its "entity-picture" to show, copy the images from
[`📂 /extras/wwww`](/extras/www/) into a folder named `📂 sysmon-mqtt` in your
Home Assistant's local webroot.

To unregister (a set of) metrics from Home Assistant, simply remove the device
from the MQTT integration (under _Settings_).

### APT-check

The APT update check refreshes its status once per hour; by default it stores
this status in a temporary file. It is possible to change this behaviour by
setting the `SYSMON_APT_CHECK` environment variable to a filename of your choice
(eg. `~/.apt-check`). In this way, APT-check's status output can be used by
other scripts.

The contents of the status file are as follows:

```text
<# of package upgrades available>

"The following packages can be upgraded:\n\<list of upgradable packages>"
```

The first line is either `0` or a positive integer, the second line is empty and
the third line contains a list of upgradable packages. The third line is
JSON-encoded and (due to a Home Assistant imposed limit) restricted to a maximum
of 255-characters (_prior_ to JSON-encoding).

While APT-check refreshes its status, the file is empty. This is done to prevent
leaving stale information in case of failures. There is thus a small chance of a
race-condition: To prevent this, wait until the status file has a non-zero size
before continuing...

## Setup

The script depends on `bash`,
**[`gawk`](https://www.gnu.org/software/gawk/manual/gawk.html)** (alternative
versions of `awk` are _not_ supported; you need
[GNU `awk`](https://www.gnu.org/software/gawk/manual/gawk.html)), `jq`, and
`mosquitto-clients`.

Additionally, `apt` and `iw` are required to report APT status and WiFi
signal-strength respectively – missing these dependencies is handled gracefully.

When running on embedded/minimal systems (e.g. DD-WRT, or OpenWRT), apart from
the above dependencies, `coreutils` most likely needs to be installed. In case
this package is further split up (like on [Entware](https://entware.net/)),
install `coreutils-mktemp`, `coreutils-nproc`, and `coreutils-timeout`.

### Broker

The script assumes the MQTT broker to be [**Mosquitto**](https://mosquitto.org/)
(and uses this assumption to validate the broker configuration).

Furthermore, the script relies on
[MQTT-persistence](https://mosquitto.org/man/mosquitto-conf-5.html) to persist
`unique_id` values for Home Assistant sensor-entities in between restarts (of
either the script or the MQTT broker). Ensure the broker has persistence (for at
least QoS level-1 messages) enabled. Otherwise, the unique ids used in Home
Assistant will be dynamic (causing duplicate entities to be created after each
restart)...

## Usage

From the shell:

```shell
./sysmon.sh [--daemon] mqtt-broker device-name [network-adapters] [rtt-hosts]
```

- `--daemon` (optional) – enable [daemon-mode](#daemon-mode); start a watchdog
  to monitor the main `sysmon-mqtt` process
- `mqtt-broker` — hostname or IP address of the MQTT-broker
- `device-name` — **human-friendly** name of the device being monitored (e.g.,
  "My Raspberry Pi"); a low-fidelity version (`my_raspberry_pi`) is
  automatically generated and used to construct MQTT-topics and Home Assistant
  entity-ids
- `network-adapters` (optional) — one or more network adapters to monitor as a
  space-delimited list (e.g., `'eth0 wlan0'`; mind the quotes when specifying
  more than one adapter)
  - If the adapter's name matches `wl*`, signal-strength is also reported
- `rtt-hosts` (optional) — one or more hosts to which to monitor the round-trip
  time as a space-delimited list (e.g., `'8.8.8.8 google.com'`; mind the quotes
  when specifying more than one hostname)

The following _optional_ environment variables can be used to further influence
the script's behaviour:

- `SYSMON_HA_DISCOVER` (default: `true`) — set to `false` to disable publishing
  to Home Assistant discovery topic
- `SYSMON_HA_TOPIC` (default: `homeassistant`) — base for the Home Assistant
  discovery topic
- `SYSMON_HA_VERSION` (default: `202308`) — specify Home Assistant version
  compatibility (as `YYYYMM`); based on this some behaviours are modified:
  - `>= 202308` do _not_ prepend device name to sensor name
    ([home-assistant/core#95159](https://github.com/home-assistant/core/pull/95159))
- `SYSMON_INTERVAL` (default: `30`) — set the interval (in seconds) at which
  metrics are reported
  - In principle, the interval can lowered all the way down to **zero** for
    real-time reporting (which _will_ negatively impact system performance)
  - When `rtt-hosts` are provided, the script automatically enforces a minimum
    reporting interval to ensure the ping-command(s) have sufficient time to
    complete
- `SYSMON_APT` (default: `true`) — set to `false` to disable reporting
  APT-related metrics (`apt` and `reboot_required`)
  - Automatically disabled when no `apt`-binary is present, _or_ when running
    inside a Docker-container (see below)
- `SYSMON_APT_CHECK` (default: `«temporary file»`) — override the location of
  the file used to store APT-check's status
- `SYSMON_RTT_COUNT` (default `4`) — number of ping-requests to send per
  iteration over which to average the round-trip time
- `SYSMON_DAEMON_LOG` (default `~/sysmon-mqtt.log`) — file to redirect all
  output to when running in [daemon-mode](#daemon-mode)

Echo the `sysmon-mqtt` version and exit:

```shell
./sysmon.sh --version
```

### Daemon-mode

As of version 1.3.0, `sysmon-mqtt` includes a simple daemon to ensure the main
monitoring process keeps running (ie, is restarted if it terminates). This is
primarily intended for embedded devices running minimal Linux-distributions
lacking amenities like [Docker](#docker) or [systemd](#systemd).

When started with `--daemon` as its _first_ argument, `sysmon-mqtt` will start
in daemon-mode and fork off a child-process to do the actual work (all arguments
after `--daemon` are passed directly to this child-process). Whenever the
child-process exits, it will be restarted by the daemon after waiting
`SYSMON_INTERVAL` seconds.

All output is redirected to `📄 ~/sysmon-mqtt.log` – this can be controlled via
the `SYSMON_DAEMON_LOG` environment variable.

To stop the daemon, send a `SIGKILL` the _daemon_-process.

### Docker

The most straightforward (if slightly constrained) way of running the script is
via the Docker-container published on
[Docker Hub](https://hub.docker.com/r/thijsputman/sysmon-mqtt) and
[GHCR](https://github.com/thijsputman/home-assistant-config/pkgs/container/sysmon-mqtt).
Container images are available for `amd64`, `arm64`, and `armhf`.

For bandwidth monitoring to work, you'll need to mount the host's `/sys`-sysfs
into the container (as is done in the below
[`📄 docker-compose.yml`](#docker-composeyml)). Alternatively, you can use
`network_mode: host` – if you need WiFi signal-strength measurements, use the
_latter_ approach (`iw` relies on the physical network adapter being accessible;
mounting `/sys` doesn't suffice).

The `/sys`-approach is preferred as it's more flexible (ie, it can be used to
gather additional information such as the device model) and offers better
security: The container's network remains isolated; instead it gains _read-only_
access to `/sys` with Docker's AppArmor policies applied to prevent access to
sensitive information.

These AppArmor policies currently _prevent_ reporting the device model from
inside the container though 😵 — see
[moby#434199](https://github.com/moby/moby/issues/43419) for details. Until that
issue is resolved, you'll need to run a privileged container (easiest, if
slightly too broad, is via `privileged: true`) which is **_not_** worth the risk
just to have the proper device model reported.

As of version 1.3.0, `sysmon-mqtt` falls back to a more generic device model in
case it can't read from `/sys/firmware` (e.g., "Raspberry Pi 4 Model B Rev 1.2"
becomes "BCM2835").

If you don't care about bandwidth monitoring (and/or the device model), the
`/sys`-mount can be removed.

Finally, the APT-related metrics are automatically _disabled_ when running
inside a Docker-container. They would report the container's state instead of
the host's state and thus make no sense. Attempting to "push" this information
into the container is unwieldy/infeasible (and probably undesirable too).

#### `docker-compose.yml`

```yaml
version: "2.3"
services:
  sysmon-mqtt:
    image: thijsputman/sysmon-mqtt:latest
    restart: unless-stopped
    # Mount host's /sys-sysfs (read-only) into the container
    volumes:
      - /sys:/sys:ro
    # Alternatively, use host networking...
    # network_mode: host
    # ...or run in privileged mode (strongly discouraged)
    # privileged: true
    environment:
      - MQTT_BROKER=
      - DEVICE_NAME=
      # Optional: Specify network adapters for bandwidth monitoring and/or
      # hostnames for round-trip times
      - NETWORK_ADAPTERS=
      - RTT_HOSTS=
      # Optional: Drop permissions to the provided UID/GID-combination
      - PUID=
      - PGID=
```

The optional environment variables provided above can of course be passed into
the Docker-container to further modify its behaviour.

### `systemd`

Alternatively, it's possible to run the script as a `systemd`-service using
something along the lines of the below configuration:

**`📄 /etc/systemd/system/sysmon-mqtt.service`**

```conf
[Unit]
Description=Simple system monitoring over MQTT
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Type=simple
Restart=on-failure
RestartSec=30
# Update the below match your environment
User=[user]
ExecStart=/usr/bin/env bash /home/<user>/sysmon.sh \
  mqtt-broker "Device Name" [network-adapters] [rtt-hosts]
# Optional: Provide additional environment variables
Environment=""

[Install]
WantedBy=multi-user.target
```

This unit configuration aims to start `sysmon-mqtt` _after_ the network comes
online. For this to work properly, the output of the below command should be
`enabled` on your system.

```shell
systemctl is-enabled systemd-networkd-wait-online.service
```

Reload, enable and start the service:

```shell
sudo systemctl daemon-reload
sudo systemctl enable sysmon-mqtt
sudo systemctl start sysmon-mqtt
```

To facilitate this setup process, a setup-script (suitable for Debian(-derived)
distributions) is provided: [`📄 install.sh`](./install.sh). Once installed,
running the script again will pull the latest version of `📄 sysmon.sh` from
GitHub.

The script requires `mqtt-broker` and `"Device Name"` to be provided.
Optionally, `network-adapters` and `rtt-hosts` can also be passed in:

```shell
./install.sh mqtt-broker "Device Name" "eth0 wlan0" "router.local 8.8.8.8"
```

Alternatively, if the service is already installed, the installer can be called
without arguments to pull the latest version of the script:

```shell
./install.sh
```

For the very brave, the script can be run from GitHub directly:

```shell
curl -fsSL https://github.com/thijsputman/sysmon-mqtt/raw/main/install.sh |
sudo -E bash -s - \
mqtt-broker "Device Name" "eth0 wlan0" "8.8.8.8 google.com"
```

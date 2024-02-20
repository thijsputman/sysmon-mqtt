# Version history

For version
[`v1.3.0`](https://github.com/thijsputman/sysmon-mqtt/releases/tag/v1.3.0) and
beyond, see
[the **Releases** on GitHub](https://github.com/thijsputman/sysmon-mqtt/releases).

- [1.2.2](#122)
- [1.2.1](#121)
- [1.2.0](#120)
- [1.1.0](#110)
- [1.0.0](#100)

## 1.2.2

- Report the overall system status (systemd-only; based on the output of
  `systemctl is-system-running`)
- When the bandwidth of a wireless adapater (ie, its name matches `wl*`) is
  monitored, its signal-strength is also reported
- `sysmon-mqtt` Version is reported as a diagnostic sensor in Home Assistant

## 1.2.1

- If `/sys/class/thermal/thermal_zone0/temp` cannot be read, `cpu_temp` is
  omitted (instead of bringing down the script)

## 1.2.0

- Respect Home Assistant 2023.8
  [MQTT entity-naming guidelines](https://github.com/home-assistant/core/pull/95159)
  (can be toggled via `SYSMON_HA_VERSION`)
- Report round-trip (ie, ping) times to user-defined host(s)
- Set `state_class` to "measurement" for all sensors that have
  `unit_of_measurement` defined
- If sensor data is missing from the JSON-payload, ensure its state is set to
  `Unknown` in Home Assistant

## 1.1.0

- Add monitoring of APT status ("updates available" and "reboot required")
- Count ZFS ARC as "free" memory

## 1.0.0

- Initial release

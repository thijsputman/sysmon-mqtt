#!/usr/bin/env bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

: "${SYSMON_INSTALL_COMMIT:=main}"

install=false

# If no service is present, always start the install-routine. Otherwise, only
# do so if at least _one_ argument is passed into this script.

if [[ ! -e /etc/systemd/system/sysmon-mqtt.service || -v 1 ]]; then

  install=true

  mqtt_host="${1:?"Missing MQTT-broker hostname!"}"
  device_name="${2:?"Missing device name!"}"
  network_adapters="${3:-}"
  rtt_hosts="${4:-}"

  # Ensure list of network adapters and RTT hosts remain quoted in the heredoc.
  # There appears no way to achieve this using something like
  # ${var:+\""$var"\"} — whatever I try, I either get no quotes or a literal
  # \" in the output...
  if [[ -n $network_adapters ]]; then
    network_adapters=\""$network_adapters"\"
  fi
  if [[ -n $rtt_hosts ]]; then
    rtt_hosts=\""$rtt_hosts"\"
    # If network_adapters is not specified, set it to a literal "" to prevent
    # rtt_hosts from being interpreted as network_adapters.
    if [[ -z $network_adapters ]]; then
      network_adapters=\"\"
    fi
  fi

fi

sysmon_url="https://raw.githubusercontent.com/thijsputman/sysmon-mqtt/\
  ${SYSMON_INSTALL_COMMIT,,}/sysmon.sh"

if [[ -e /etc/systemd/system/sysmon-mqtt.service ]]; then
  systemctl stop sysmon-mqtt
  if $install; then
    systemctl disable sysmon-mqtt
    rm /etc/systemd/system/sysmon-mqtt.service
  fi
# Assumes dependencies are only relevant on first ever install...
else
  apt update
  apt install -y \
    bash \
    gawk \
    iw \
    jq \
    mosquitto-clients
fi

mkdir -p "$HOME/.local/bin"
sysmon_target="$HOME/.local/bin/sysmon-mqtt"

wget -O "$sysmon_target" "$(tr -d ' ' <<< "$sysmon_url")"
chown "${SUDO_USER:-$(whoami)}:" "$sysmon_target"
chmod +x "$sysmon_target"

if $install; then

  # Pass a (normalised) commit-ish along to the service definition
  if [[ $SYSMON_INSTALL_COMMIT =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    SYSMON_INSTALL_COMMIT=${SYSMON_INSTALL_COMMIT,,}
    SYSMON_INSTALL_COMMIT=${SYSMON_INSTALL_COMMIT:0:7}
  fi

  # Hoist all safe "SYSMON_*" variables into the service definition
  sysmon_envs=()
  while IFS='=' read -r name value; do
    if [[ $name =~ ^SYSMON_.*$ ]] && [[ ! $value =~ [\\\"$'\n\r'%] ]]; then
      sysmon_envs+=("Environment=\"$name=$value\"")
    fi
  done < <(env)

  tee /etc/systemd/system/sysmon-mqtt.service <<- EOF > /dev/null
		[Unit]
		Description=Simple system monitoring over MQTT
		After=network-online.target
		Wants=network-online.target
		StartLimitIntervalSec=120
		StartLimitBurst=3

		[Service]
		Type=simple
		IgnoreSIGPIPE=false
		Restart=on-failure
		RestartSec=30
		User=${SUDO_USER:-$(whoami)}
		ExecStart=/usr/bin/env bash "$sysmon_target" \\
		  $mqtt_host \\
		  "$device_name" \\
		  $network_adapters \\
		  $rtt_hosts
		$(printf '%s\n' "${sysmon_envs[@]}")

		[Install]
		WantedBy=multi-user.target
	EOF
  # N.B. heredoc should be indented with tabs...

  systemctl daemon-reload
  systemctl enable sysmon-mqtt

fi

if [[ ! -e /etc/systemd/system/sysmon-mqtt.service ]]; then
  echo 'Install failed – sysmon-mqtt service not present!' >&2
  exit 1
fi

systemctl start sysmon-mqtt
exit $?

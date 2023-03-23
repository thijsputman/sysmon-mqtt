#!/usr/bin/env bash

set -eo pipefail

# Defaults for optional settings (from global environment)

: "${SYSMON_HA_DISCOVER:=true}"
: "${SYSMON_HA_TOPIC:=homeassistant}"
: "${SYSMON_INTERVAL:=30}"
: "${SYSMON_IN_DOCKER:=false}"
: "${SYSMON_APT:=true}"

# Compute number of ticks per hour; additionally, forces $SYSMON_INTERVAL to
# base10 — exits in case of an invalid value for the interval
hourly_ticks=$((3600/10#$SYSMON_INTERVAL))

# APT-related metrics make no sense when running inside a Docker-container or
# when APT is not present on the system
if [ "$SYSMON_IN_DOCKER" = true ] || ! command -v apt &> /dev/null ; then
  SYSMON_APT=false
fi

# Positional parameters

mqtt_host="${1:?"Missing MQTT-broker hostname!"}"
device_name="${2:?"Missing device name!"}"
read -r -a eth_adapters <<< "$3"

# Exit-trap handler

goodbye(){
  rc="$?"
  mosquitto_pub -r -q 1 -h "$mqtt_host" \
    -t "sysmon/$device/connected" -m 0 || true
  # Reset EXIT-trap to prevent running twice (due to "set -e")
  trap - EXIT
  exit "$rc"
}

# Clean parameters to be used in MQTT-topic names — reduce them to lowercase
# alphanumeric and underscores; exit if nothing remains

mqtt_clean(){

  param=$(echo "${1//[^A-Za-z0-9_ -]/}" |
    tr -s ' -' _ | tr '[:upper:]' '[:lower:]')

  if [ -z "$param" ] ; then
    echo "Invalid parameter '$1' supplied!" ; exit 1
  fi

  echo "$param"
}

device=$(mqtt_clean "$device_name")
ha_topic=$(mqtt_clean "$SYSMON_HA_TOPIC")

# Test the broker (assumes Mosquitto) — exits on failure
mosquitto_sub -C 1 -h "$mqtt_host" -t \$SYS/broker/version

mosquitto_pub -r -q 1 -h "$mqtt_host" \
  -t "sysmon/$device/connected" -m '-1' || true

ha_discover(){

  local name=${1}
  local attribute=${2}
  read -r -a class_icon <<< "$3"
  local unit=${4}
  local entity=${5:-sensor}

  # Attempt to retrieve existing UUID; otherwise generate a new one

  if config=$(mosquitto_sub -h "$mqtt_host" -C 1 -W 3 \
    -t "${ha_topic}/$entity/sysmon/${device}_${attribute//\//_}/config" \
    2> /dev/null) ; then
    unique_id=$(jq -r -c '.unique_id' <<< "$config" 2> /dev/null) \
      || true # This ensures invalid JSON-payloads are ignored
  else
    unique_id=""
  fi

  if ! [[ "$unique_id" =~ ^[0-9a-z-]{36}$ ]] ; then
    unique_id=$(< /proc/sys/kernel/random/uuid)
  fi

  # Construct "device_class"- and/or "icon"-properties

  local device_class=""
  local icon=""

  if [ -n "${class_icon[0]}" ] ; then
    if [ "${#class_icon[@]}" -gt 1 ] ; then
        device_class="${class_icon[0]}"
        icon="${class_icon[1]}"
    elif [[ "${class_icon[0]}" =~ ^mdi: ]] ; then
      icon="${class_icon[0]}"
    else
      device_class="${class_icon[0]}"
    fi
  fi

  # Construct Home Assistant discovery-payload
  #
  # A combination of "expire_after" and "availability/value_template" is used
  # to determine the sensor's availability. In principle, "expire_after" and a
  # simple ("payload > 0") template would suffice — the provided template
  # handles edge cases (MQTT component/HA reload) more gracefully though...

  local value_template="value_json.${attribute//\//.} | float(0) | round(2)"
  local state_topic="sysmon/$device/state"
  local expire_after=$((10#$SYSMON_INTERVAL*3))
  local entity_picture=""
  local availability_template
  availability_template=$(tr -d '\n' <<- EOF
    'online' if (value | int(0) | as_datetime) + timedelta(
      seconds = ${expire_after}) >= now() else 'offline'
		EOF
  ) # N.B., EOF-line should be indented with tabs!

  # Heartbeat and APT have somewhat different setups

  if [ "$attribute" = "heartbeat" ] ; then
    expire_after=0
    state_topic="sysmon/$device/connected"
    value_template="(value | int(0) | as_datetime)"
  elif [ "$attribute" = "apt" ] ; then
    expire_after=0
    entity_picture="/local/debian.png"
    value_template="value_json.${attribute//\//.} | to_json"
  elif [ "$attribute" = "reboot_required" ] ; then
    expire_after=0
    value_template=$(tr -d '\n' <<- EOF
      'ON' if (value_json.${attribute//\//.} | int(0)) == 1 else 'OFF'
			EOF
    ) # N.B., EOF-line should be indented with tabs!
  fi

  # For expiry of 0, the "simple" behaviour is actually what we want...
  if [ "$expire_after" -eq 0 ] ; then
    availability_template="'online' if value | int(0) > 0 else 'offline'"
  fi

  local payload
  # For "model", the use of cat is intentional (it redirects "not found"-errors
  # to /dev/null). Furthermore, no model is reported in Docker-containers while
  # <https://github.com/moby/moby/issues/43419> remains open.
  # shellcheck disable=SC2002
  payload=$(tr -s ' ' <<- EOF
    {
      "name": $(echo -n "$device_name $name" | jq -R -s '.'),
      "object_id": "${device}_${attribute//\//_}",
      "unique_id": "$unique_id",
      "device": {
          "identifiers": "sysmon_${device}",
          "name": $(echo -n "$device_name" | jq -R -s '.'),
          "manufacturer": "sysmon-mqtt",
          "model": "$(cat /sys/firmware/devicetree/base/model \
            2> /dev/null | tr -d '\0' || true)",
          "sw_version": "$(uname -smr)"
      },
      $([ -n "$device_class" ] && echo "\"device_class\": \"$device_class\",")
      $([ -n "$icon" ] && echo "\"icon\": \"$icon\",")
      $([ -n "$entity_picture" ] && \
        echo "\"entity_picture\": \"$entity_picture\",")
      "state_topic": "$state_topic",
      $([ -n "$unit" ] && echo "\"unit_of_measurement\": \"$unit\",")
      $([ -n "$value_template" ] && \
        echo "\"value_template\": \"{{ $value_template }}\",")
      "expire_after": "$expire_after",
      "availability": {
        "topic": "sysmon/$device/connected",
        "payload_available": "online",
        "payload_not_available": "offline",
        "value_template": "{{ $availability_template }}"
      }
    }
		EOF
  ) # N.B., EOF-line should be indented with tabs!

  mosquitto_pub -r -q 1 -h "$mqtt_host" \
    -t "${ha_topic}/$entity/sysmon/${device}_${attribute//\//_}/config" \
    -m "$payload" || true
}

if [ "$SYSMON_HA_DISCOVER" = true ] ; then

  ha_discover 'Heartbeat' 'heartbeat' 'timestamp mdi:heart-pulse'
  ha_discover 'CPU temperature' cpu_temp temperature '°C'
  ha_discover 'CPU load' cpu_load 'mdi:chip' '%'
  ha_discover 'Memory usage' mem_used 'mdi:memory' '%'

  for adapter in "${eth_adapters[@]}" ; do

    ha_discover "Bandwidth in (${adapter})" "bandwidth/${adapter}/rx" \
      'data_rate mdi:download-network' 'kbit/s'
    ha_discover "Bandwidth out (${adapter})" "bandwidth/${adapter}/tx" \
      'data_rate mdi:upload-network' 'kbit/s'

  done

  if [ "$SYSMON_APT" = true ] ; then
    ha_discover 'APT upgrades' 'apt' 'mdi:package-up' '' 'update'
    ha_discover 'Reboot required' 'reboot_required' 'mdi:restart' '' \
      'binary_sensor'
  fi

fi

_join() { local IFS="$1" ; shift ; echo "$*" ; }

cpu_cores=$(nproc --all)
rx_prev=() ; tx_prev=()
first_loop=true
hourly=true
ticks=0

while true ; do

  # CPU temperature
  cpu_temp=$(awk '{printf "%3.2f", $0/1000 }' < \
    /sys/class/thermal/thermal_zone0/temp)

  # Load (1-minute load / # of cores)
  cpu_load=$(uptime | \
    awk "match(\$0, /load average: ([0-9\.]*),/, \
      result){printf \"%3.2f\", result[1]*100/$cpu_cores}")

  # Memory usage (1 - total / available)
  mem_used=$(free | awk 'NR==2{printf "%3.2f", (1-($7/$2))*100 }')

  # Bandwith (in kbps; measured over the "sysmon interval")

  payload_bw=()

  for i in "${!eth_adapters[@]}" ; do

    adapter="${eth_adapters[i]}"

    # Attempt to strip $adapter down to a single path-component; exits if the
    # adapter doesn't exist
    rx=$(< "/sys/class/net/${adapter%%/*}/statistics/rx_bytes")
    tx=$(< "/sys/class/net/${adapter%%/*}/statistics/tx_bytes")

    # Only run when "prev" is initialised
    if [ "${#rx_prev[@]}" -eq "${#eth_adapters[@]}" ] ; then

      payload_bw+=("$(tr -s ' ' <<- EOF
        "$adapter": {
          "rx": "$(
            echo $(((rx-rx_prev[i])/10#$SYSMON_INTERVAL)) |
              awk '{printf "%.2f", $1*8/1000}'
            )",
          "tx": "$(
            echo $(((tx-tx_prev[i])/10#$SYSMON_INTERVAL)) |
              awk '{printf "%.2f", $1*8/1000}'
          )"
        }
				EOF
      )") # N.B., EOF-line should be indented with tabs!

    # Otherwise send an empty payload
    else printf -v payload_bw '"%s": {"rx": "0", "tx": "0"}' "$adapter" ; fi

    rx_prev[i]=$rx
    tx_prev[i]=$tx

  done

  # APT & reboot-required

  payload_apt=()
  reboot_required=0

  if [ "$SYSMON_APT" = true ] ; then

    if [ -v apt_check ] && [ -s "$apt_check" ] ; then

      payload_apt+=("$(tr -s ' ' <<- EOF
        "title": "APT",
        "installed_version": "0",
        "latest_version": "$(head -n 1 "$apt_check")",
        "release_summary": $(tail -n +3 "$apt_check")
				EOF
      )") # N.B., EOF-line should be indented with tabs!

    fi

    # Run apt-check and its processing once per hour

    if [ "$hourly" = true ] ; then

      apt_check=$(mktemp -t sysmon.apt-check.XXXXXXXX)

      # Fork it off so we don't block on waiting for this to complete
      (
        # shellcheck disable=SC1004
        apt_simulate=$(apt --simulate upgrade 2> /dev/null | awk \
          'BEGIN{RS=""} ; match($0, \
            /The following packages will be upgraded:(.* not upgraded.)/,
          result){printf "%s", result[1]}')

        apt_upgrades=$(tail -n 1 <<< "$apt_simulate" | awk \
          'match($0, /([0-9]+) upgraded,/, result){printf "%d", result[1]}')
        if [ -z "$apt_upgrades" ] ; then
          apt_upgrades=0
          apt_summary="\"No packages can be upgraded.\""
        else
          apt_summary=$(head -n -1 <<< "$apt_simulate" | tr -d -s '\n' ' ')
          apt_summary=$(printf '%s\n\n%s' \
            "The following packages can be upgraded:" "${apt_summary:1:255}" | \
            jq -R -s '.')
        fi

        printf '%s\n\n%s' "$apt_upgrades" "$apt_summary" > "$apt_check"
      ) &

    fi

    # Reboot-required

    if [ -s /var/run/reboot-required ] ; then
      reboot_required=1
    fi

  fi

  # Construct payload

  payload=$(tr -s ' ' <<- EOF
    {
      "cpu_temp": "$cpu_temp",
      "cpu_load": "$cpu_load",
      "mem_used": "$mem_used",
      "bandwidth": {
        $(_join , "${payload_bw[@]}")
      },
      "reboot_required": "$reboot_required",
      "apt": {
        $(_join , "${payload_apt[@]}")
      }
    }
		EOF
  ) # N.B., EOF-line should be indented with tabs!

  mosquitto_pub -h "$mqtt_host" \
    -t "sysmon/$device/state" -m "$payload" || true

  # Start publishing a "heartbeat" from the second iteration onward; during the
  # _first_ iteration, setup the exit-trap: This ensures errors during init (and
  # those while gathering the first set of metrics) are not trapped and will
  # leave the connected-state as "-1".

  if [ "$first_loop" = false ] ; then

    mosquitto_pub -r -q 1 -h "$mqtt_host" \
      -t "sysmon/$device/connected" -m "$(date +%s)" || true

  else trap goodbye INT HUP TERM EXIT ; fi

  first_loop=false

  # Track ticks and hourly-trigger
  ticks=$((ticks+1))
  hourly=false
  if [ "$ticks" -gt "$hourly_ticks" ] ; then hourly=true ; ticks=0 ; fi

  sleep "$((10#$SYSMON_INTERVAL))s" &
  wait $!

done

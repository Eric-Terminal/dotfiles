# 读取 macOS 电源管理提供的 USB-C 端口输出遥测。
_portpower-values() {
  emulate -L zsh

  local power_plist="$1"
  local detail_index controller_index port_index
  local max_power loser_reason watts voltage current
  local -A role
  local -A power_mw voltage_mv current_ma

  role=(1 OFF 2 OFF)
  power_mw=(1 0 2 0)
  voltage_mv=(1 0 2 0)
  current_ma=(1 0 2 0)

  # 获胜的 PD 输入控制器决定充电器接在哪个物理端口。
  for controller_index in 0 1; do
    max_power="$(
      printf '%s' "$power_plist" |
        plutil -extract "0.PortControllerInfo.${controller_index}.PortControllerMaxPower" raw -o - - 2>/dev/null
    )" || continue
    loser_reason="$(
      printf '%s' "$power_plist" |
        plutil -extract "0.PortControllerInfo.${controller_index}.PortControllerLoserReason" raw -o - - 2>/dev/null
    )" || continue

    (( max_power > 0 && loser_reason == 0 )) || continue

    port_index=$(( controller_index + 1 ))
    role[$port_index]=IN
    power_mw[$port_index]="$(
      printf '%s' "$power_plist" |
        plutil -extract '0.PowerTelemetryData.SystemPowerIn' raw -o - - 2>/dev/null
    )" || power_mw[$port_index]=0
    voltage_mv[$port_index]="$(
      printf '%s' "$power_plist" |
        plutil -extract '0.PowerTelemetryData.SystemVoltageIn' raw -o - - 2>/dev/null
    )" || voltage_mv[$port_index]=0
    current_ma[$port_index]="$(
      printf '%s' "$power_plist" |
        plutil -extract '0.PowerTelemetryData.SystemCurrentIn' raw -o - - 2>/dev/null
    )" || current_ma[$port_index]=0
  done

  # 输出设备自带 PortIndex，因此不依赖数组顺序判断物理端口。
  for detail_index in 0 1; do
    port_index="$(
      printf '%s' "$power_plist" |
        plutil -extract "0.PowerOutDetails.${detail_index}.PortIndex" raw -o - - 2>/dev/null
    )" || continue

    [[ "$port_index" == 1 || "$port_index" == 2 ]] || continue

    watts="$(
      printf '%s' "$power_plist" |
        plutil -extract "0.PowerOutDetails.${detail_index}.Watts" raw -o - - 2>/dev/null
    )" || watts=0
    voltage="$(
      printf '%s' "$power_plist" |
        plutil -extract "0.PowerOutDetails.${detail_index}.AdapterVoltage" raw -o - - 2>/dev/null
    )" || voltage=0
    current="$(
      printf '%s' "$power_plist" |
        plutil -extract "0.PowerOutDetails.${detail_index}.Current" raw -o - - 2>/dev/null
    )" || current=0

    role[$port_index]=OUT
    power_mw[$port_index]="$watts"
    voltage_mv[$port_index]="$voltage"
    current_ma[$port_index]="$current"
  done

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${role[1]}" "${power_mw[1]}" "${voltage_mv[1]}" "${current_ma[1]}" \
    "${role[2]}" "${power_mw[2]}" "${voltage_mv[2]}" "${current_ma[2]}"
}

portpower() {
  emulate -L zsh
  setopt localtraps

  if [[ ! -t 1 ]]; then
    printf 'portpower：需要在交互式终端中运行。\n' >&2
    return 1
  fi

  local c_bold=$'\e[1m'
  local c_cyan=$'\e[36m'
  local c_green=$'\e[32m'
  local c_yellow=$'\e[33m'
  local c_red=$'\e[31m'
  local c_dim=$'\e[2;37m'
  local c_reset=$'\e[0m'
  local power_plist values timestamp rendered=0
  local p1_role p1_mw p1_mv p1_ma p2_role p2_mw p2_mv p2_ma
  local p1_color p2_color

  trap 'printf "\e[0m"; return 130' INT TERM

  while true; do
    power_plist="$(ioreg -a -r -c AppleSmartBattery 2>/dev/null)"
    values="$(_portpower-values "$power_plist")"
    IFS=$'\t' read -r \
      p1_role p1_mw p1_mv p1_ma \
      p2_role p2_mw p2_mv p2_ma <<< "$values"

    if [[ "$p1_role" == IN ]]; then
      p1_color="$c_cyan"
    elif [[ "$p1_role" == OFF ]]; then
      p1_color="$c_dim"
    elif (( p1_mw < 5000 )); then
      p1_color="$c_green"
    elif (( p1_mw < 10000 )); then
      p1_color="$c_yellow"
    else
      p1_color="$c_red"
    fi

    if [[ "$p2_role" == IN ]]; then
      p2_color="$c_cyan"
    elif [[ "$p2_role" == OFF ]]; then
      p2_color="$c_dim"
    elif (( p2_mw < 5000 )); then
      p2_color="$c_green"
    elif (( p2_mw < 10000 )); then
      p2_color="$c_yellow"
    else
      p2_color="$c_red"
    fi

    timestamp="$(date '+%H:%M:%S')"
    (( rendered )) && printf '\e[2A'

    printf '\r\e[2K%sUSB-C P1%s  %s%-3s  %6.3f W  %6.3f V  %4d mA%s  %s%s%s\n' \
      "$c_bold" "$c_reset" "$p1_color" "$p1_role" \
      "$(( p1_mw / 1000.0 ))" "$(( p1_mv / 1000.0 ))" "$p1_ma" "$c_reset" \
      "$c_dim" "$timestamp" "$c_reset"
    printf '\r\e[2K%sUSB-C P2%s  %s%-3s  %6.3f W  %6.3f V  %4d mA%s\n' \
      "$c_bold" "$c_reset" "$p2_color" "$p2_role" \
      "$(( p2_mw / 1000.0 ))" "$(( p2_mv / 1000.0 ))" "$p2_ma" "$c_reset"

    rendered=1

    sleep 1
  done
}

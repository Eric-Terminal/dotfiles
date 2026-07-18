# 读取 macOS 电源管理提供的 USB-C 端口输出遥测。
_portpower-values() {
  emulate -L zsh

  local power_plist="$1"
  local detail_index controller_index port_index
  local max_power loser_reason watts voltage current
  local -A role
  local -A power_mw voltage_mv current_ma limit_mw

  role=(1 OFF 2 OFF)
  power_mw=(1 0 2 0)
  voltage_mv=(1 0 2 0)
  current_ma=(1 0 2 0)
  limit_mw=(1 0 2 0)

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
    limit_mw[$port_index]="$max_power"
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
    max_power="$(
      printf '%s' "$power_plist" |
        plutil -extract "0.PowerOutDetails.${detail_index}.PDPowermW" raw -o - - 2>/dev/null
    )" || max_power=15000

    role[$port_index]=OUT
    power_mw[$port_index]="$watts"
    voltage_mv[$port_index]="$voltage"
    current_ma[$port_index]="$current"
    limit_mw[$port_index]="$max_power"
  done

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${role[1]}" "${power_mw[1]}" "${voltage_mv[1]}" "${current_ma[1]}" "${limit_mw[1]}" \
    "${role[2]}" "${power_mw[2]}" "${voltage_mv[2]}" "${current_ma[2]}" "${limit_mw[2]}"
}

# 输入与输出使用不同的真彩渐变，避免把正常的高输入功率误标为危险。
_portpower-color() {
  emulate -L zsh

  local role="$1"
  local power_mw="$2"
  local limit_mw="$3"
  local half_limit r g b

  if [[ "$role" == OFF ]]; then
    REPLY=$'\e[2;37m'
    return
  fi

  (( limit_mw > 1 )) || limit_mw=2
  (( power_mw < 0 )) && power_mw=0
  (( power_mw > limit_mw )) && power_mw=limit_mw

  if [[ "$role" == IN ]]; then
    # 输入：天蓝色逐渐过渡到紫红色。
    r=$(( 56 + (217 - 56) * power_mw / limit_mw ))
    g=$(( 189 + (70 - 189) * power_mw / limit_mw ))
    b=$(( 248 + (239 - 248) * power_mw / limit_mw ))
  else
    # 输出：绿色经黄色过渡到红色。
    half_limit=$(( limit_mw / 2 ))
    if (( power_mw <= half_limit )); then
      r=$(( 52 + (250 - 52) * power_mw / half_limit ))
      g=$(( 211 + (204 - 211) * power_mw / half_limit ))
      b=$(( 153 + (21 - 153) * power_mw / half_limit ))
    else
      r=$(( 250 + (244 - 250) * (power_mw - half_limit) / half_limit ))
      g=$(( 204 + (63 - 204) * (power_mw - half_limit) / half_limit ))
      b=$(( 21 + (94 - 21) * (power_mw - half_limit) / half_limit ))
    fi
  fi

  printf -v REPLY '\e[38;2;%d;%d;%dm' "$r" "$g" "$b"
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
  local c_dim=$'\e[2;37m'
  local c_reset=$'\e[0m'
  local power_plist values timestamp rendered=0
  local p1_role p1_mw p1_mv p1_ma p1_limit
  local p2_role p2_mw p2_mv p2_ma p2_limit
  local p1_color p2_color

  trap 'printf "\e[0m"; return 130' INT TERM

  while true; do
    power_plist="$(ioreg -a -r -c AppleSmartBattery 2>/dev/null)"
    values="$(_portpower-values "$power_plist")"
    IFS=$'\t' read -r \
      p1_role p1_mw p1_mv p1_ma p1_limit \
      p2_role p2_mw p2_mv p2_ma p2_limit <<< "$values"

    _portpower-color "$p1_role" "$p1_mw" "$p1_limit"
    p1_color="$REPLY"
    _portpower-color "$p2_role" "$p2_mw" "$p2_limit"
    p2_color="$REPLY"

    timestamp="$(date '+%H:%M:%S')"
    (( rendered )) && printf '\e[3A'

    printf '\r\e[2K%sUSB-C 端口功率%s  %s%s%s  %s硬件采样约 6 秒%s\n' \
      "$c_bold$c_cyan" "$c_reset" "$c_bold" "$timestamp" "$c_reset" "$c_dim" "$c_reset"
    printf '\r\e[2K%sP1%s  %s%-3s  %6.3f W%s %s/ %4.1f W  %6.3f V  %4d mA%s\n' \
      "$c_bold" "$c_reset" "$p1_color" "$p1_role" "$(( p1_mw / 1000.0 ))" "$c_reset" \
      "$c_dim" "$(( p1_limit / 1000.0 ))" "$(( p1_mv / 1000.0 ))" "$p1_ma" "$c_reset"
    printf '\r\e[2K%sP2%s  %s%-3s  %6.3f W%s %s/ %4.1f W  %6.3f V  %4d mA%s\n' \
      "$c_bold" "$c_reset" "$p2_color" "$p2_role" "$(( p2_mw / 1000.0 ))" "$c_reset" \
      "$c_dim" "$(( p2_limit / 1000.0 ))" "$(( p2_mv / 1000.0 ))" "$p2_ma" "$c_reset"

    rendered=1

    sleep 1
  done
}

#!/usr/bin/env zsh

set -euo pipefail

source "${0:A:h:h}/shell/port-power.zsh"

fixture='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>PortControllerInfo</key>
    <array>
      <dict>
        <key>PortControllerMaxPower</key><integer>30000</integer>
        <key>PortControllerLoserReason</key><integer>0</integer>
      </dict>
      <dict>
        <key>PortControllerMaxPower</key><integer>0</integer>
        <key>PortControllerLoserReason</key><integer>1</integer>
      </dict>
    </array>
    <key>PowerTelemetryData</key>
    <dict>
      <key>SystemPowerIn</key><integer>20000</integer>
      <key>SystemVoltageIn</key><integer>20000</integer>
      <key>SystemCurrentIn</key><integer>1000</integer>
    </dict>
    <key>PowerOutDetails</key>
    <array>
      <dict>
        <key>PortIndex</key><integer>2</integer>
        <key>Watts</key><integer>3900</integer>
        <key>AdapterVoltage</key><integer>5155</integer>
        <key>Current</key><integer>756</integer>
      </dict>
    </array>
  </dict>
</array>
</plist>'

actual="$(_portpower-values "$fixture")"
expected=$'IN\t20000\t20000\t1000\tOUT\t3900\t5155\t756'

if [[ "$actual" != "$expected" ]]; then
  printf '端口功率解析结果不符合预期。\n预期：%q\n实际：%q\n' "$expected" "$actual" >&2
  exit 1
fi

printf 'portpower 测试通过。\n'

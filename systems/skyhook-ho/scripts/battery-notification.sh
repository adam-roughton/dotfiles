#!/usr/bin/env sh

LOW_THRESHOLD=10
CRIT_THRESHOLD=3

perc=$(cat /sys/class/power_supply/BAT0/capacity)

if [[ -z "$perc" ]]; then exit 0
elif [[ "$perc" -lt "$CRIT_THRESHOLD" ]]; then notify-send -u critical "Battery is critical! ($perc%)"
elif [[ "$perc" -lt "$LOW_THRESHOLD" ]]; then notify-send -u normal "Battery is low! ($perc%)"
fi


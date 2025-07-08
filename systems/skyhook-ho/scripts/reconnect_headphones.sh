#!/usr/bin/env bash

bluetoothctl disconnect 00:1B:66:B4:3B:C4
sleep 1
bluetoothctl connect 00:1B:66:B4:3B:C4

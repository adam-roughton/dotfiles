#!/usr/bin/env bash

bluetoothctl disconnect 50:1B:6A:0B:7B:A9
sleep 1
bluetoothctl connect 50:1B:6A:0B:7B:A9

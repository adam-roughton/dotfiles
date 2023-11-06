#!/usr/bin/env bash

xsetroot -solid '#222255' &
autorandr -c &
feh --recursive --randomize --bg-fill ~/.wallpapers
picom --config ~/.config/picom.conf &

sleep 1
unclutter &
nm-applet &
parcellite &
pasystray &
xautolock -locker "i3lock --color '#332233'"  -time 5 -detectsleep &

from qutebrowser.config.configfiles import ConfigAPI
from qutebrowser.config.config import ConfigContainer

import sys, os

config = config
c = c

config.load_autoconfig()
config.source('redirector.py')

c.aliases = {}

c.tabs.tabs_are_windows = True
c.tabs.show = "multiple"

c.editor.command = ["kitty", "vim", "{}"]

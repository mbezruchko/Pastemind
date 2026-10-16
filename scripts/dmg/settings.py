# dmgbuild's settings for Pastemind.dmg (scripts/release.sh): the app and a link to Applications on the background
# scripts/dmg/background.py draws, the window without its bars, the volume with the app's icon.
#   dmgbuild -s scripts/dmg/settings.py -D app=<Pastemind.app> Pastemind <out.dmg>    (from the repository's root)
import os.path

application = defines["app"]

format = "ULFO"            # LZFSE: smaller than zlib, opens on macOS 10.11 and later
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"

background = "scripts/dmg/background.tiff"
# 400 points of background under a title bar of about 32.
window_rect = ((200, 160), (660, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True

icon_size = 128
text_size = 13
# The icons' centres (background.py draws the shelf and the arrow for these).
icon_locations = {os.path.basename(application): (190, 196), "Applications": (470, 196)}

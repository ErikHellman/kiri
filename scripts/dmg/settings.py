# dmgbuild settings for Kiri's disk image (scripts/dmg.sh passes the defines).
# The window, icon size and icon positions must match the picture drawn by
# scripts/dmg/dmg-background.mjs.
import os.path

app = defines["app"]                  # path to Kiri.app
here = defines["here"]                # scripts/dmg
app_name = os.path.basename(app)

format = "ULFO"                       # LZFSE, opens on macOS 10.11 and later
filesystem = "HFS+"
size = None                           # sized to fit

files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("volume_icon")     # .VolumeIcon.icns, the mounted disk's icon

# background.png plus background@2x.png beside it, combined into one TIFF.
background = os.path.join(here, "background.png")

# Content size 660 x 392 points, the picture's size; Finder's title bar is
# added on top (WINDOW_CHROME in dmg.sh).
window_rect = ((200, 140), (660, 392 + int(defines.get("chrome", "0"))))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 128

icon_locations = {
    app_name: (170, 204),
    "Applications": (490, 204),
}
hide_extensions = [app_name]

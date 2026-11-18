# dmgbuild settings for Cadence's DMG (used by scripts/dmg.sh).
# Layout must match scripts/make-dmg-background.swift: 640×400 window, icons centred at (160, 200) and (480, 200).
# `defines` comes from dmgbuild -D: app, background, volume_icon.
import os.path

app = defines["app"]  # noqa: F821 — injected by dmgbuild
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]  # noqa: F821

background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (640, 400))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"

icon_size = 128
text_size = 13
icon_locations = {
    app_name: (160, 200),
    "Applications": (480, 200),
}
arrange_by = None
hide_extension = [app_name]

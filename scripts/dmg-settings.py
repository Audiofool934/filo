"""Finder layout for the release image; dmgbuild supplies defines."""
from pathlib import Path

application = Path(defines["app"]).resolve()
files = [str(application)]
symlinks = {"Applications": "/Applications"}
icon = str(application / "Contents/Resources/filo.icns")
background = defines["background"]
format = "UDZO"
filesystem = "HFS+"
window_rect = ((160, 160), (760, 430))
icon_locations = {"filo.app": (220, 225), "Applications": (540, 225)}
icon_size = 96
text_size = 13
default_view = "icon-view"
show_icon_preview = False
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False
include_icon_view_settings = True
include_list_view_settings = False
# Never set FinderInfo on the signed app: it invalidates strict verification.

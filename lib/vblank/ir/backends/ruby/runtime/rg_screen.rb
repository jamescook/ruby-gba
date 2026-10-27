# THE SCREEN, as far as a game that draws nothing goes through it: switched off until the first
# frame is set up, one page, no window moved over it, no sprites. Every game passes through
# this part, even one that only counts; drawing anything arrives with the rest of the picture.
#
# The picture is kept as the console keeps it, a 15-bit colour a pixel, row by row.

RG_SCREEN_WIDTH = 240
RG_SCREEN_HEIGHT = 160
RG_SCREEN_CELLS = RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT
RG_SWITCHED_OFF = 0x7FFF # what a switched-off display shows: plain white

def rg_screen_setup
  @rg_screen_held = 0 # switched off until the first frame (Framebuffer#held=)
  @rg_screen_pixels = Array.new(RG_SCREEN_CELLS, 0)
  @rg_scene = -1      # the scene that has taken over, none before the first
end

# --- scenes ---
#
# A scene taking over puts its own scenery up and takes the last one's down, and crosses to its
# own kind of screen. In a game that draws nothing there is no scenery to take down, and no kind
# of screen was ever said (saying one is part of the picture), so there is nothing to cross from.

def rg_scene_enter(scene)
  @rg_scene = scene
end

def rg_scene_take_down(_brings_scenery); end
def rg_scene_redraw_sprites; end
def rg_screen_cross_to(_kind, _two_pages) = 0

# A rebuild of the whole view, owed after the scenery changes: nothing is ever owed here.
def rg_screen_paint_owed_rebuild; end

# A program that waits for frames shows nothing until its first frame is set up.
def rg_screen_hold(value)
  @rg_screen_held = value
end

def rg_screen_frame_started
  @rg_screen_held = 0
end

# The frame boundary, where a tear-free screen trades its pages; one page has nothing to trade.
def rg_screen_frame_ended; end

def rg_screen_camera_x = 0
def rg_screen_camera_y = 0
def rg_screen_drawn_count = 0
def rg_screen_two_pages = 0

# The page a viewer is looking at as it is stored (Framebuffer#to_a)...
def rg_screen_stored = @rg_screen_pixels

# ...and as it is shown (Framebuffer#shown): a switched-off display shows plain white.
def rg_screen_shown
  @rg_screen_held != 0 ? Array.new(RG_SCREEN_CELLS, RG_SWITCHED_OFF) : @rg_screen_pixels
end

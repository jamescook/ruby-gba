# THE GAME'S PICTURE, drawn in software: the console's screen as an array of colors, and
# everything the game does to it — drawing, backgrounds, sprites, the window over the picture,
# fades and tints, a picture in blocks, see-through layers, bends and the light.
#
# Each method says which of the interpreter's it answers for (in backends/reference.rb and
# reference/framebuffer.rb), because the interpreter is what this is checked against pixel for
# pixel. That includes the parts that look like bookkeeping — when the whole view is rebuilt,
# which scenery is up, what a scene takes down as it arrives — since each decides what a pixel
# holds on some frame.
#
# A color is the console's: fifteen bits, five each of red, green and blue, red lowest, kept as
# a whole number. A sprite's picture is kept as signed sixteen-bit numbers, RG_NOT_DRAWN (-1)
# where what is behind shows, and a background's tiles as unsigned ones, RG_SEE_THROUGH (0xFFFF)
# there; a color painted is held to sixteen bits (& 0xFFFF) as it goes in.
#
# A sprite's pictures and a background's tiles arrive ready to draw, in the game's tables
# (@rg_game_images, @rg_game_tile_pixels and the rest): which pixels show, and the colors of each
# list they can be drawn with, were worked out when the game was built.
#
# The screen's size is the console's the game is built for: RG_SCREEN_WIDTH and RG_SCREEN_HEIGHT
# come first in the game's class, written by the lowering (Lowering#console_text).

RG_SCREEN_CELLS = RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT
RG_SWITCHED_OFF = 0x7FFF # what a switched-off display shows: plain white

# The kinds of screen a `screen` can name.
RG_BITMAP = 0
RG_TILED = 1
RG_ROTOZOOM = 2

RG_FADE_WHOLE_SCREEN = 0
RG_FADE_INSIDE = 1
RG_FADE_OUTSIDE = 2

RG_NOT_DRAWN = -1      # a sprite picture's pixel where what is behind shows
RG_SEE_THROUGH = 0xFFFF # a tile's pixel where the layer behind shows
RG_SOLID = -1          # a thing in no see-through layer
RG_NO_NAME = -1
RG_NOT_IN_BLOCKS = -1
RG_EVERY_SCENE = -1
RG_NEVER_ARRIVES = -2
RG_NO_LAYER = -1
RG_NOT_A_BAR = -1
RG_NOT_PAINTED = -1
RG_CELL_EMPTY = -1
RG_MAX_SPRITES = 512
RG_MAX_BACKGROUNDS = 64
RG_MAX_SEE_THROUGH = 16
RG_AREAS_DEEP = 64
RG_IMAGE_FIELDS = 3

# Each layer the game can be seen through is RG_ST_FIELDS numbers in @rg_game_see_through.
RG_ST_AMOUNTS_WRITTEN = 0
RG_ST_ONE_AMOUNT = 1
RG_ST_HOLDS_A_SPRITE = 2
RG_ST_FIELDS = 3

# Each background is RG_BG_FIELDS numbers in @rg_game_backgrounds, in the order the stack draws
# them: the size of its tiles; its first map among @rg_game_maps and how many it can be handed
# while the game runs; the entry that keeps what the game does to its name (two scenes can each
# declare a background by one name); whether it never comes round at its map's edge; where its
# tiles start in @rg_game_tile_pixels; its scene (RG_EVERY_SCENE for scenery every screen shows,
# RG_NEVER_ARRIVES for a scene nothing hands the screen to), its depth, whether it comes up with
# its scene, and how far forward the layer it named is (RG_NO_LAYER for none); its see-through
# layer or RG_SOLID; whether it is bent; how far forward a placed fade's layer can be and still
# leave it as drawn; how many tiles it has and how many steps of colors it can be told; whether
# it goes into blocks and whether it can turn; and where its painted tiles and their colors are,
# or RG_NOT_PAINTED.
RG_BG_TILE_W = 0
RG_BG_TILE_H = 1
RG_BG_FIRST_MAP = 2
RG_BG_SHOWABLE_MAPS = 3
RG_BG_KEPT_BY = 4
RG_BG_NEVER_WRAPS = 5
RG_BG_TILES_START = 6
RG_BG_SCENE = 7
RG_BG_LEVEL = 8
RG_BG_ON_ARRIVAL = 9
RG_BG_STACK_PLACE = 10
RG_BG_SEE_THROUGH = 11
RG_BG_BENT = 12
RG_BG_FADE_PLACE = 13
RG_BG_TILES = 14
RG_BG_COLOR_STEPS = 15
RG_BG_IN_BLOCKS = 16
RG_BG_CAN_TURN = 17
RG_BG_PAINTED = 18
RG_BG_RUN_COLORS = 19
RG_BG_BAR_TOP = 20
RG_BG_FIELDS = 21

# Each run of tiles the game paints from a list is RG_RUN_FIELDS numbers in @rg_game_tile_runs.
RG_RUN_TILES = 0
RG_RUN_WIDTH = 1
RG_RUN_HEIGHT = 2
RG_RUN_PLACES = 3
RG_RUN_FIRST_IMAGE = 4
RG_RUN_IMAGES = 5
RG_RUN_FIELDS = 6
RG_RUN_IMAGE_FIELDS = 17
RG_RUN_TILE_SIDE = 8
RG_RUN_TILE_PIXELS = RG_RUN_TILE_SIDE * RG_RUN_TILE_SIDE
RG_PLACES_IN_RUN_COLORS = 16

# Each map is RG_MAP_FIELDS numbers in @rg_game_maps.
RG_MAP_CELLS = 0
RG_MAP_COLS = 1
RG_MAP_ROWS = 2
RG_MAP_GRID_COLS = 3
RG_MAP_GRID_ROWS = 4
RG_MAP_FIELDS = 5

# The places in @rg_game_picture_sizes.
RG_SIZE_BACKGROUNDS = 0
RG_SIZE_DEPTHS = 1
RG_SIZE_ALWAYS_UP = 2
RG_SIZE_REBUILT_WHOLE = 3
RG_SIZE_SEE_THROUGH = 4
RG_SIZE_SCREEN_KINDS_CHANGE = 5
RG_SIZE_LARGEST_BLOCK = 6
RG_SIZE_RUNS = 7
RG_SIZE_RUN_PIXELS = 8
RG_SIZE_IMAGES = 9

RG_NOBODY_ASKED = -1
RG_NO_CELL = -1        # a cell of a saved patch that hung off the picture
RG_NOTHING_ON_SHEET = -1
RG_NO_PLACE = -1
# The display counts the rows of a turned sprite's box in this many lines that come round.
RG_TURNED_BOX_LINES = 256

# The part of the screen drawing is held inside (Framebuffer#draw_inside), when it is held.
RgArea = Struct.new(:in_force, :left, :top, :right, :bottom)

# The two colors each mixed cell was mixed from (Framebuffer @mixed_tops), for a tint that moves
# the color table, which reaches each side before the mix (see rg_shown_color). +is_mixed+ is
# nought for a cell painted solid. Kept for the picture, and for the scenery kept apart to put
# back behind a sprite, so a cell put back is still a mix.
class RgMixes
  attr_reader :is_mixed, :tops, :unders

  def initialize
    @is_mixed = Array.new(RG_SCREEN_CELLS, 0)
    @tops = Array.new(RG_SCREEN_CELLS, 0)
    @unders = Array.new(RG_SCREEN_CELLS, 0)
  end
end

# One sprite on screen this frame. One that turns or resizes carries its angle and its size for
# this frame, and whether its size ever changes.
RgPlaced = Struct.new(:sprite, :image, :x, :y, :level, :turned, :angle, :size, :resizes)

# How a background is turned, once it has been turned or resized at all (Reference @bg_affine).
RgTurn = Struct.new(:turned, :angle, :size, :pivot_x, :pivot_y)

# A FADE PLACED IN THE STACK (Reference @fade_placed): whether one is in force, how far forward the
# layer it sits under is among the layers the game declared, which way it fades, and how far.
RgPlacedFade = Struct.new(:in_force, :layer_place, :toward_white, :steps)

def rg_screen_setup
  # TWO PAGES, OR ONE (Framebuffer#paged=). A tear-free screen is two pictures: the display shows
  # one while the game draws into the other, and they trade places between frames, so nobody ever
  # sees a half-drawn picture. Drawing always lands on @rg_pixels and the viewer always reads
  # @rg_viewed; with one page those are the same picture. Which page is which is told by identity
  # (equal?), never by what they hold.
  @rg_first_page = Array.new(RG_SCREEN_CELLS, 0)
  @rg_second_page = Array.new(RG_SCREEN_CELLS, 0)
  @rg_backdrop = 0 # the colour shown wherever nothing is drawn (Reference @backdrop)
  @rg_pixels = @rg_first_page
  @rg_viewed = @rg_first_page
  @rg_shown = Array.new(RG_SCREEN_CELLS, 0)
  # Where drawing goes: the picture, or for a moment the copy of the scenery kept to put back under
  # a sprite (Reference#drawing_into).
  @rg_target = @rg_first_page
  @rg_area = RgArea.new(false, 0, 0, 0, 0)
  @rg_outer_areas = []
  # Where the window onto the picture sits (Framebuffer#camera_to): screen (0, 0) shows what was
  # drawn at (camera_x, camera_y). Nothing drawn moves.
  @rg_camera_x = 0
  @rg_camera_y = 0
  # The patches of picture saved under bitmap sprites, by buffer number (Reference @backing).
  @rg_saved_patches = []
  # THE SCENERY WITH NOTHING ON IT (Reference @scene_fb): the backdrop and every background up,
  # painted once and kept, to put back under a sprite drawn straight onto a picture that is not
  # rebuilt every frame.
  @rg_scenery = Array.new(RG_SCREEN_CELLS, 0)
  @rg_scenery_kept = false
  @rg_screen_held = 0 # switched off until the first frame (Framebuffer#held=)
  @rg_frames_begun = false # a frame boundary has been reached (Reference @uses_frames)
  @rg_kind = -1 # the kind of screen up; none before the first `screen`
  @rg_rebuild_pending = false # a rebuild of the whole view is owed (Reference#request_repaint)
  @rg_scene = -1
  # What a display does to the finished picture: one effect at a time (Framebuffer#fade_to).
  @rg_fade_white = 0
  @rg_fade_steps = 0
  @rg_tint_mode = :none # :none, :toward or :color
  @rg_tint_white = 0
  @rg_tint_color = 0
  @rg_tint_steps = 0
  @rg_tint_by_display = false
  # THE PICTURE IN FLAT BLOCKS (Reference @block): how many pixels a block is each way, 1 being the
  # picture as drawn; and the size a screen the game paints is read in (Framebuffer @block).
  @rg_block = 1
  @rg_read_block = 1
  # A background being put into blocks is painted onto a sheet of its own first, rows before
  # columns (Reference#paint_scenery_in_blocks).
  @rg_sheet = Array.new(RG_SCREEN_CELLS, RG_NOTHING_ON_SHEET)
  @rg_onto_sheet = false
  @rg_rows_tall = 1
  @rg_placed_fade = RgPlacedFade.new(false, RG_NO_LAYER, 0, 0)
  @rg_fading_what_is_painted = false # Framebuffer @paint_toward
  # WHAT IS PAINTED FROM HERE ON IS MIXED with what is already in the cell (Framebuffer @through):
  # [sixteenths of what is painted, sixteenths of what is under it].
  @rg_mixing = false
  @rg_mixed_by = [16, 0]
  @rg_picture_mixes = RgMixes.new
  @rg_scenery_mixes = RgMixes.new
  @rg_mixed_cells_by = [16, 0]
  # THE PICTURE WITH NO SPRITES ON IT (Framebuffer @scenery), in a game with a sprite in a
  # see-through layer: a see-through sprite is mixed with this and never with a sprite behind it.
  @rg_picture_without_sprites = Array.new(RG_SCREEN_CELLS, 0)
  @rg_painting_sprite = false
  @rg_seen_through_answer = nil
  # Scenery up, in the order it went up (Reference @bg_shown): one entry for every time a
  # background is put up, even one already up, exactly as the interpreter keeps it.
  @rg_shown_backgrounds = []
  # What the game does to a background, kept by the entry that keeps its NAME (rg_keeper_of): the
  # map its cells hold now, the run's own copy of them and the entry whose map that is (Reference
  # @bg_maps, kept as [which, cells, of]), its scroll (@bg_scroll), whether it is shown from its
  # corner this pass (@bg_from_corner), the step of colors the game last named for it, from which
  # each entry works out the set of its tiles it is drawn from (@bg_colors), and its turn
  # (@bg_affine).
  @rg_cells_now = Array.new(RG_MAX_BACKGROUNDS) { [0, nil, 0] }
  @rg_scrolls = Array.new(RG_MAX_BACKGROUNDS) { [0, 0] }
  @rg_from_corner = Array.new(RG_MAX_BACKGROUNDS, false)
  @rg_bar_tops = Array.new(RG_MAX_BACKGROUNDS, 0) # where each status bar was last placed
  @rg_bar_placed = Array.new(RG_MAX_BACKGROUNDS, false) # ...and whether it has been
  @rg_any_from_corner = false
  @rg_corners_expired = false
  @rg_colors_told = Array.new(RG_MAX_BACKGROUNDS, 0) # one more than the step of colors last named, 0 for none
  @rg_turns = Array.new(RG_MAX_BACKGROUNDS) { RgTurn.new(false, 0, 0, 0, 0) }
  # The sprites on screen this frame: being said, and as the last rebuild draws them.
  @rg_drawing = []
  @rg_sprite_layer = []
  # Where each sprite was last drawn straight onto the picture, by its number (Reference @obj_prev).
  @rg_last_drawn = Array.new(RG_MAX_SPRITES)
  # See-through layers: the one being asked about and its answer, and its shares as kept when a
  # rebuild was asked for (Reference @owed_weights) and as last told (@see_through_shown).
  @rg_asked_layer = RG_NOBODY_ASKED
  @rg_answered = [0, 0]
  @rg_pending_shares = Array.new(RG_MAX_SEE_THROUGH)
  @rg_told_shares = Array.new(RG_MAX_SEE_THROUGH)
  @rg_fade_side = RG_FADE_WHOLE_SCREEN
  @rg_fade_area = [0, 0, 0, 0]
  # WHAT THE GAME HAS PAINTED (Reference @bitmaps, for a run's tiles and pictures): every run's
  # pixels as places in its colors, place 0 see-through; and the images painted from them.
  @rg_painted_places = nil
  @rg_painted_images = nil
  # Bends: the background and line being asked about and the answer, and every line of every bent
  # background as the gap between frames last worked it out.
  @rg_asked_bend = [RG_NOBODY_ASKED, 0, 0]
  @rg_bend_lines = Array.new(RG_MAX_BACKGROUNDS)
  # A light: each row's lit span, how many sixteenths the rest is darkened by, the row being asked
  # about, and whether the scene that just ran has it off.
  @rg_shade_spans = Array.new(RG_SCREEN_HEIGHT) { [0, 0] }
  @rg_shade_steps = 0
  @rg_shade_row = 0
  @rg_shade_off = false
end

# --- small arithmetic ---

# The game's numbers are whole; Ruby's / and % already round down, which is what the picture's
# arithmetic wants wherever a number can be below nought.
def rg_clamp_wide(value, low, high) = value < low ? low : (value > high ? high : value)

def rg_background_field(background, field) = @rg_game_backgrounds[(background * RG_BG_FIELDS) + field]

# --- the picture itself (Framebuffer) ---

def rg_on_screen?(x, y) = x >= 0 && x < RG_SCREEN_WIDTH && y >= 0 && y < RG_SCREEN_HEIGHT

# Framebuffer#paintable?: on the screen, and inside the area drawing is held to when it is.
def rg_paintable?(x, y)
  return false unless rg_on_screen?(x, y)

  area = @rg_area
  !area.in_force || (x >= area.left && x < area.right && y >= area.top && y < area.bottom)
end

# Framebuffer#mix_see_through: a see-through layer's color over what is under it. Each channel is
# widened to eight bits first, its share of each side added and only then the sixteenth dropped,
# and the answer taken back to five bits. Past a whole, a channel stops at its brightest.
#
# The three channels are written out rather than looped over: this runs for every pixel of a
# see-through layer, and a loop over them costs a block call each and a shift worked out each
# time, on top of the sums.
#
# A channel is WIDENED from five bits to eight by repeating its top bits underneath ((c << 3) |
# (c >> 2), Framebuffer#widen_channel), so the brightest five-bit value, 31, becomes the brightest
# eight-bit one, 255, rather than 248; every channel helper here widens that way.
def rg_mixed_with_under(color, under, by)
  top = by[0]
  bottom = by[1]
  red = rg_mixed_channel_with_under(color & 0x1F, under & 0x1F, top, bottom)
  green = rg_mixed_channel_with_under((color >> 5) & 0x1F, (under >> 5) & 0x1F, top, bottom)
  blue = rg_mixed_channel_with_under((color >> 10) & 0x1F, (under >> 10) & 0x1F, top, bottom)
  red | (green << 5) | (blue << 10)
end

# One channel of rg_mixed_with_under, five bits in and five out.
def rg_mixed_channel_with_under(have, below, top, bottom)
  mix = ((((have << 3) | (have >> 2)) * top) + (((below << 3) | (below >> 2)) * bottom)) / 16
  (mix > 255 ? 255 : mix) >> 3
end

# Framebuffer#darkened_by_display: each channel widened to eight bits and placed in its own byte,
# taken +steps+ sixteenths of the way to black there, and brought back to five bits. Done in the
# channel's own byte as the interpreter does it, which rounds how much the first channel loses
# down and how much the other two lose up.
#
# The channels are written out rather than looped over, as in rg_mixed_with_under.
def rg_darkened_by_display(color, steps)
  return color if steps == 0

  red = rg_darkened_channel(color & 0x1F, 0, steps)
  green = rg_darkened_channel((color >> 5) & 0x1F, 8, steps)
  blue = rg_darkened_channel((color >> 10) & 0x1F, 16, steps)
  (red | (green << 5) | (blue << 10)) & 0xFFFF
end

# One channel of rg_darkened_by_display, placed +byte_shift+ bits up while it is darkened.
def rg_darkened_channel(channel, byte_shift, steps)
  placed = ((channel << 3) | (channel >> 2)) << byte_shift
  ((placed - ((placed * steps) / 16)) >> byte_shift) >> 3
end

# Framebuffer#brightened_by_display: each channel widened to eight bits and given +steps+
# sixteenths of the headroom it has left there, then brought back to five bits.
def rg_brightened_by_display(color, steps)
  return color if steps == 0

  rg_brightened_channel(color & 0x1F, steps) | (rg_brightened_channel((color >> 5) & 0x1F, steps) << 5) |
    (rg_brightened_channel((color >> 10) & 0x1F, steps) << 10)
end

# One channel of rg_brightened_by_display, five bits in and five out.
def rg_brightened_channel(channel, steps)
  have = (channel << 3) | (channel >> 2)
  (have + (((255 - have) * steps) / 16)) >> 3
end

# Framebuffer#faded_by_display: the display's own fade toward black or white.
def rg_faded_by_display(color, white, steps)
  white != 0 ? rg_brightened_by_display(color, steps) : rg_darkened_by_display(color, steps)
end

# Framebuffer#apply_placed_fade: a color as it is painted while a placed fade reaches it.
def rg_faded_as_painted(color)
  color &= 0xFFFF
  return color unless @rg_fading_what_is_painted

  rg_faded_by_display(color, @rg_placed_fade.toward_white, @rg_placed_fade.steps)
end

# The mixed sides kept for +page+: the picture being drawn into, or the scenery kept apart; nil
# for any other page, which is never shown with a tint and never put back.
def rg_mixes_of(page)
  return @rg_picture_mixes if page.equal?(@rg_pixels)

  page.equal?(@rg_scenery) ? @rg_scenery_mixes : nil
end

# Framebuffer#blend_into_cell: a color on its way into the cell at +at+ of +page+, which holds
# +under+. The fade a placed fade asks for first, then the mix a see-through layer asks for. The
# cell keeps the two colors of its mix, or stops being a mix when painted solid.
def rg_into_cell(color, under, page, at)
  painted = rg_faded_as_painted(color)
  kept = rg_mixes_of(page)
  if kept
    kept.is_mixed[at] = @rg_mixing ? 1 : 0
    if @rg_mixing
      kept.tops[at] = painted
      kept.unders[at] = under
    end
  end
  @rg_mixing ? rg_mixed_with_under(painted, under, @rg_mixed_by) : painted
end

# Reference#see_through_sprites?: is any sprite in a see-through layer? The game's, and it never
# changes, so it is worked out once.
def rg_sprites_seen_through?
  return @rg_seen_through_answer unless @rg_seen_through_answer.nil?

  @rg_seen_through_answer = Array.new(@rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]) do |layer|
    @rg_game_see_through[(layer * RG_ST_FIELDS) + RG_ST_HOLDS_A_SPRITE]
  end.any? { |holds| holds != 0 }
end

# Whether the picture with no sprites on it is kept beside what is being drawn into
# (Framebuffer#keep_scenery). The copy of the scenery kept to put back under sprites keeps none.
def rg_keeps_picture_without_sprites? = !@rg_target.equal?(@rg_scenery) && rg_sprites_seen_through?

# Framebuffer#set_pixel: a cell drawing may not land on is dropped. A sprite is mixed with the
# picture as it is with no sprite on it, where that is kept, and anything else with what is
# already in the cell.
def rg_set_pixel(x, y, color)
  return unless rg_paintable?(x, y)

  at = (y * RG_SCREEN_WIDTH) + x
  kept = rg_keeps_picture_without_sprites?
  under = kept && @rg_painting_sprite ? @rg_picture_without_sprites : @rg_target
  painted = rg_into_cell(color, under[at], @rg_target, at)
  @rg_target[at] = painted
  @rg_picture_without_sprites[at] = painted if kept && !@rg_painting_sprite
end

# Framebuffer#fill_rect: every cell of the rectangle, each through rg_set_pixel. Walking only the
# part on the screen paints the same cells.
def rg_fill_cells(x, y, width, height, color)
  left = x < 0 ? 0 : x
  top = y < 0 ? 0 : y
  right = x + width
  bottom = y + height
  right = RG_SCREEN_WIDTH if right > RG_SCREEN_WIDTH
  bottom = RG_SCREEN_HEIGHT if bottom > RG_SCREEN_HEIGHT
  py = top
  while py < bottom
    px = left
    while px < right
      rg_set_pixel(px, py, color)
      px += 1
    end
    py += 1
  end
end

# Framebuffer#clear: the whole picture, or the area drawing is held to and no more.
def rg_clear_to(color)
  area = @rg_area
  return rg_fill_cells(area.left, area.top, area.right - area.left, area.bottom - area.top, color) if area.in_force

  painted = rg_faded_as_painted(color)
  @rg_target.fill(painted)
  kept = rg_mixes_of(@rg_target)
  kept&.is_mixed&.fill(0)
  return unless rg_keeps_picture_without_sprites?

  @rg_picture_without_sprites.fill(painted)
end

def rg_screen_clear(color) = rg_clear_to(color)
def rg_screen_fill_rect(x, y, width, height, color) = rg_fill_cells(x, y, width, height, color)

# Reference#exec_inside: the area before is kept, to be given back by rg_screen_inside_ended.
def rg_screen_inside(x, y, width, height)
  rg_fault("more than #{RG_AREAS_DEEP} `inside` blocks are open at once") if @rg_outer_areas.length >= RG_AREAS_DEEP
  @rg_outer_areas.push(@rg_area)
  @rg_area = RgArea.new(true, x, y, x + width, y + height)
end

# A frame may end between the two. The picture is read whole whatever area is open, and nothing
# is painted after a run stops.
def rg_screen_inside_ended
  @rg_area = @rg_outer_areas.pop
end

# Reference#exec_camera
def rg_screen_camera(x, y)
  @rg_camera_x = x
  @rg_camera_y = y
end

def rg_screen_camera_x = @rg_camera_x
def rg_screen_camera_y = @rg_camera_y

# Framebuffer#paged=. Going to two pages, the one drawn so far goes on being drawn into and a blank
# one is shown, which is what the console does on the way in. Going back to one, the two are the
# page holding the drawing.
def rg_show_pages(two)
  return if (two != 0) == !@rg_pixels.equal?(@rg_viewed)

  if two == 0
    @rg_viewed = @rg_pixels
    return
  end
  @rg_viewed = @rg_pixels.equal?(@rg_first_page) ? @rg_second_page : @rg_first_page
  @rg_viewed.fill(0)
end

# Reference#exec_save_region: the patch of the picture at (x, y), as it is stored — what is
# really in the picture, wherever the window sits, and whatever area drawing is held to. A cell off
# the screen is remembered as nothing.
def rg_patch_save(buffer, width, height, x, y)
  patch = @rg_saved_patches[buffer] ||= Array.new(width * height, RG_NO_CELL)
  height.times do |row|
    width.times do |col|
      px = x + col
      py = y + row
      patch[(row * width) + col] = rg_on_screen?(px, py) ? @rg_pixels[(py * RG_SCREEN_WIDTH) + px] : RG_NO_CELL
    end
  end
end

# Reference#exec_restore_region: a patch never saved puts nothing back, and neither does a cell
# remembered as nothing.
def rg_patch_restore(buffer, width, height, x, y)
  patch = @rg_saved_patches[buffer] or return

  height.times do |row|
    width.times do |col|
      color = patch[(row * width) + col]
      rg_set_pixel(x + col, y + row, color) if color != RG_NO_CELL
    end
  end
end

def rg_screen_pixel(x, y, color) = rg_set_pixel(x, y, color)

# Two colors for a line of text, and the test that says which.
def rg_pick_color(showing, color, picked) = showing != 0 ? picked : color

# Reference#exec_draw_text: each lit pixel of each letter, from the text's top left. The points
# are (dx, dy) pairs in +points+, +count+ of them from pair +from+ on.
def rg_screen_points(x, y, color, points, count, from = 0)
  count.times do |i|
    at = 2 * (from + i)
    rg_set_pixel(x + points[at], y + points[at + 1], color)
  end
end

# Reference#exec_draw_digit: +starts+ says where each of the ten digits' points begin.
def rg_screen_digit(value, x, y, color, points, starts)
  return if value < 0 || value > 9

  rg_screen_points(x, y, color, points, starts[value + 1] - starts[value], starts[value])
end

# --- see-through layers ---

def rg_see_through_layers = @rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]
def rg_see_through_field(layer, field) = @rg_game_see_through[(layer * RG_ST_FIELDS) + field]

def rg_see_through_asked(layer) = layer == @rg_asked_layer ? 1 : 0

def rg_see_through_answer(shows, behind)
  @rg_answered = [shows, behind]
end

# IR::SeeThrough.nearest_steps and .floor_steps: an amount out of 100 as sixteenths.
def rg_nearest_sixteenths(amount) = rg_clamp_wide(((amount * 16) + 50) / 100, 0, 16)
def rg_whole_sixteenths(amount) = rg_clamp_wide((amount * 16) / 100, 0, 16)

# Reference#live_see_through_weights, through IR::SeeThrough.weights: a layer's two shares from
# its amounts as the game works them out now. Given one amount, what is behind takes its share
# rounded down and the layer whatever is left of a whole; given two, each is taken to the nearest
# sixteenth.
def rg_shares_now(layer)
  @rg_asked_layer = layer
  rg_game_see_through_amounts
  @rg_asked_layer = RG_NOBODY_ASKED
  shows, behind = @rg_answered
  if rg_see_through_field(layer, RG_ST_ONE_AMOUNT) != 0
    under = rg_whole_sixteenths(behind)
    return [16 - under, under]
  end
  [rg_nearest_sixteenths(shows), rg_nearest_sixteenths(behind)]
end

# Reference#layer_has_anything?: a background showing now, or a sprite anywhere, since whether a
# sprite is shown is a variable too.
def rg_layer_holds_anything?(layer)
  return true if rg_see_through_field(layer, RG_ST_HOLDS_A_SPRITE) != 0

  @rg_game_picture_sizes[RG_SIZE_BACKGROUNDS].times.any? do |bg|
    rg_showing?(bg) && rg_background_field(bg, RG_BG_SEE_THROUGH) == layer
  end
end

# Reference#capture_see_through_weights. A rebuild is painted later than it is asked for, and the
# game's variables can move in between, so the amounts a game works out are read when the rebuild
# is asked for and the painting uses those. Only for a layer with something in it that could be on
# screen: nothing is worked out that painting would not have worked out.
def rg_keep_shares_for_pending_rebuild
  rg_see_through_layers.times do |layer|
    keep = rg_see_through_field(layer, RG_ST_AMOUNTS_WRITTEN) == 0 && rg_layer_holds_anything?(layer)
    @rg_pending_shares[layer] = keep ? rg_shares_now(layer) : nil
  end
end

def rg_forget_kept_shares
  rg_see_through_layers.times { |layer| @rg_pending_shares[layer] = nil }
end

# Reference#fading?: is a fade in force that takes the display's blend? While such a fade runs a
# see-through layer is solid. A fade that walks the colors sets no fade amount and is never found
# here, and the copy of the scenery kept to put back under sprites never has one. A fade placed in
# the stack is the game's and takes the blend whichever is being painted.
def rg_fade_holds_blend?
  return @rg_placed_fade.steps > 0 if @rg_placed_fade.in_force

  !@rg_target.equal?(@rg_scenery) && @rg_fade_steps > 0
end

# Reference#set_see_through_for, for scenery: mixing on for a thing in a see-through layer, off for
# anything else. +layer+ is RG_SOLID for a thing in none.
def rg_mix_as_layer(layer)
  @rg_painting_sprite = false
  @rg_mixing = layer != RG_SOLID && !rg_fade_holds_blend?
  return unless @rg_mixing

  @rg_mixed_by = @rg_mixed_cells_by = @rg_pending_shares[layer] || rg_shares_now(layer)
end

# Reference#set_see_through_for, for a sprite: the same, and what is painted is a sprite's, so it
# is mixed with the picture as it is with no sprite on it and stays off that picture.
def rg_mix_as_sprite(sprite)
  rg_mix_as_layer(@rg_game_sprite_see_through[sprite])
  @rg_painting_sprite = true
end

def rg_mix_nothing
  @rg_mixing = false
  @rg_painting_sprite = false
end

# --- effects over the finished picture (Framebuffer#faded) ---

# Framebuffer#walked_toward: a fade that walks the colors, in five bits a channel, each channel
# moved a truncated share of the way to black or white.
def rg_walked_toward(color, white, steps)
  return color if steps == 0

  out = 0
  3.times do |channel|
    c = (color >> (5 * channel)) & 0x1F
    c = white != 0 ? c + (((31 - c) * steps) / 32) : c - ((c * steps) / 32)
    out |= c << (5 * channel)
  end
  out
end

# Framebuffer#mixed and #mixed_by_display: the two shares added, and only then the fraction
# dropped. The display mixes at eight bits a channel; a game writing tinted colors, at five.
#
# The channels are written out rather than looped over, as in rg_mixed_with_under.
def rg_mixed(color, toward, steps, by_display)
  return color if steps == 0

  keep = 32 - steps
  red = rg_mixed_channel(color & 0x1F, toward & 0x1F, keep, steps, by_display)
  green = rg_mixed_channel((color >> 5) & 0x1F, (toward >> 5) & 0x1F, keep, steps, by_display)
  blue = rg_mixed_channel((color >> 10) & 0x1F, (toward >> 10) & 0x1F, keep, steps, by_display)
  red | (green << 5) | (blue << 10)
end

# One channel of rg_mixed, five bits in and five out.
def rg_mixed_channel(have, want, keep, steps, by_display)
  return ((have * keep) + (want * steps)) / 32 unless by_display

  (((((have << 3) | (have >> 2)) * keep) + (((want << 3) | (want >> 2)) * steps)) / 32) >> 3
end

# Framebuffer#faded. +fade_here+ is false where a fade held to a rectangle does not reach.
def rg_faded_where(color, fade_here)
  case @rg_tint_mode
  when :toward
    # On the plain bitmap screen the display does a walked fade, in sixteenths.
    return rg_faded_by_display(color, @rg_tint_white, @rg_tint_steps >> 1) if @rg_tint_by_display

    return rg_walked_toward(color, @rg_tint_white, @rg_tint_steps)
  when :color
    # The display counts in sixteenths, the even thirty-seconds, so an odd step is dropped.
    steps = @rg_tint_by_display ? @rg_tint_steps & ~1 : @rg_tint_steps
    return rg_mixed(color, @rg_tint_color, steps, @rg_tint_by_display)
  end
  return color unless fade_here

  rg_faded_by_display(color, @rg_fade_white, @rg_fade_steps)
end

def rg_faded(color) = rg_faded_where(color, true)

# Framebuffer#shown_color: the stored cell at +at+ with the fade or tint in force. A cell a
# see-through layer was mixed into, under a tint, is mixed again from its two colors tinted: a tint
# on a screen drawn through a color table moves the colors the display then mixes.
def rg_shown_color(at, stored, fade_here)
  if @rg_tint_mode == :none || !@rg_pixels.equal?(@rg_viewed) || @rg_picture_mixes.is_mixed[at] == 0
    return rg_faded_where(stored, fade_here)
  end

  rg_mixed_with_under(rg_faded(@rg_picture_mixes.tops[at]), rg_faded(@rg_picture_mixes.unders[at]), @rg_mixed_cells_by)
end

# Framebuffer#fade_reaches?: does the display's fade reach the screen pixel (x, y)?
def rg_fade_reaches?(x, y)
  return true if @rg_fade_side == RG_FADE_WHOLE_SCREEN

  left, top, right, bottom = @rg_fade_area
  within = x >= left && x < right && y >= top && y < bottom
  @rg_fade_side == RG_FADE_INSIDE ? within : !within
end

# Reference#exec_fade, through Framebuffer#fade_steps_to or, for a fade that walks the colors,
# #tint_steps_to. +placed+ is true for a fade placed in the stack under the layer at +layer_place+.
#
# Over the whole screen it is laid over the picture as the screen is read, so nothing drawn
# changes. Placed in the stack it is painted into the picture, so the picture is built again right
# here, and again by the fade that takes a placed one's place, which has to take it back out. A
# fade that takes the display's blend takes it from a see-through layer and hands it back as it
# lifts, so the picture is built again at each of those two moments as well.
def rg_fade_to(placed, layer_place, toward_white, steps, walked)
  took_the_blend = rg_fade_holds_blend?
  was_placed = @rg_placed_fade.in_force
  @rg_placed_fade = RgPlacedFade.new(placed, layer_place, toward_white, steps)
  if walked != 0
    @rg_tint_mode = :toward
    @rg_tint_white = toward_white
    @rg_tint_steps = steps
    @rg_tint_by_display = rg_tint_mixed_by_display? # Reference#fade_by_tint
    @rg_fade_steps = 0
  else
    @rg_fade_white = toward_white
    @rg_fade_steps = placed ? 0 : steps
    @rg_tint_mode = :none
  end
  blend_changed_hands = rg_see_through_layers > 0 && rg_fade_holds_blend? != took_the_blend
  rg_request_repaint if was_placed || placed || blend_changed_hands
end

def rg_screen_fade(toward_white, steps, walked)
  @rg_fade_side = RG_FADE_WHOLE_SCREEN
  rg_fade_to(false, RG_NO_LAYER, toward_white, steps, walked)
end

def rg_screen_fade_in_area(reaches, left, top, right, bottom, toward_white, steps)
  @rg_fade_side = reaches
  @rg_fade_area = [left, top, right, bottom]
  rg_fade_to(false, RG_NO_LAYER, toward_white, steps, 0)
end

def rg_screen_fade_under(layer_place, toward_white, steps, walked)
  @rg_fade_side = RG_FADE_WHOLE_SCREEN
  rg_fade_to(true, layer_place, toward_white, steps, walked)
end

# Reference#tint_by_display?: does the display mix a tint in as it draws, which only the plain
# bitmap screen does, on a console that blends? Every other screen has it mixed into a colour table.
def rg_tint_mixed_by_display? = rg_painted_screen? && @rg_pixels.equal?(@rg_viewed) && RG_CONSOLE_BLENDS

# Reference#exec_tint, through Framebuffer#tint_steps_to. A tint takes the place of whatever fade
# was in force, one placed in the stack included, and the picture is built again when a fade that
# held a see-through layer solid, or was painted into the picture, goes.
def rg_screen_tint(color, steps)
  took_the_blend = rg_fade_holds_blend?
  was_placed = @rg_placed_fade.in_force
  @rg_placed_fade.in_force = false
  @rg_tint_mode = :color
  @rg_tint_color = color
  @rg_tint_steps = steps
  @rg_tint_by_display = rg_tint_mixed_by_display?
  @rg_fade_steps = 0
  blend_changed_hands = rg_see_through_layers > 0 && rg_fade_holds_blend? != took_the_blend
  rg_request_repaint if was_placed || blend_changed_hands
end

# Backends::FadeSteps.steps
def rg_fade_steps(amount, fraction_bits, walked)
  levels = walked != 0 ? 32 : 16
  if fraction_bits < 0
    sixteenths = rg_whole_sixteenths(amount)
    return walked != 0 ? sixteenths * 2 : sixteenths
  end
  rg_clamp_wide((amount * levels) / (100 << fraction_bits), 0, levels)
end

# --- scenery ---

# The entry that keeps what the game does to this background's name (RG_BG_KEPT_BY): itself,
# unless another scene declared a background by the same name after it.
def rg_keeper_of(background) = rg_background_field(background, RG_BG_KEPT_BY)

# Reference#background_up: the declaration of this background's name a line naming it means: the
# one on the screen up now, where two scenes each declare one by the name, or the keeping entry
# where none of them is up.
def rg_declaration_up(background)
  keeper = rg_keeper_of(background)
  @rg_game_picture_sizes[RG_SIZE_BACKGROUNDS].times do |bg|
    return bg if rg_keeper_of(bg) == keeper && rg_showing?(bg)
  end
  keeper
end

# Reference#background_swap: which set of its tiles this entry is drawn from now. 0 for the colors
# they were drawn in, which is also what a number naming none of its steps means, or one more than
# the step the game last named.
def rg_tile_set_now(background)
  step = @rg_colors_told[rg_keeper_of(background)] - 1
  step >= 0 && step < rg_background_field(background, RG_BG_COLOR_STEPS) ? step + 1 : 0
end

# Reference#scroll_shown: where a background's window sits on the display now.
def rg_scroll_shown(background)
  keeper = rg_keeper_of(background)
  @rg_from_corner[keeper] ? [0, 0] : @rg_scrolls[keeper]
end

# Reference#forget_expired_corners
def rg_forget_expired_corners
  return unless @rg_corners_expired

  @rg_corners_expired = false
  @rg_from_corner.fill(false)
  @rg_any_from_corner = false
end

# Reference#mark_from_corner
def rg_mark_from_corner(background)
  rg_forget_expired_corners
  @rg_from_corner[rg_keeper_of(background)] = true
  @rg_any_from_corner = true
end

# Where map number +which+ of a background's own maps starts in @rg_game_maps.
def rg_map_entry(background, which) = RG_MAP_FIELDS * (rg_background_field(background, RG_BG_FIRST_MAP) + which)

# Reference#map_of: where the map a background's cells hold now starts in @rg_game_maps. That is
# the run's own copy for the name where there is one, which is a copy of one of the maps of the
# entry it was made from; and the first of this background's own maps where there is none.
def rg_map_now(background)
  which, cells, of = @rg_cells_now[rg_keeper_of(background)]
  cells ? rg_map_entry(of, which) : rg_map_entry(background, 0)
end

def rg_map_cols(background) = @rg_game_maps[rg_map_now(background) + RG_MAP_COLS]
def rg_map_rows(background) = @rg_game_maps[rg_map_now(background) + RG_MAP_ROWS]

def rg_in_map?(background, row, col)
  row >= 0 && row < rg_map_rows(background) && col >= 0 && col < rg_map_cols(background)
end

# Where a cell of the map is among its cells, which are kept row after row.
def rg_cell_place(background, row, col) = (row * rg_map_cols(background)) + col

# Reference#map_of: what a cell holds NOW, in the run's own copy where there is one. Below nought
# where it holds no tile.
def rg_map_cell(background, row, col)
  return RG_CELL_EMPTY unless rg_in_map?(background, row, col)

  own = @rg_cells_now[rg_keeper_of(background)][1]
  return own[rg_cell_place(background, row, col)] if own

  @rg_game_map_cells[@rg_game_maps[rg_map_now(background) + RG_MAP_CELLS] + rg_cell_place(background, row, col)]
end

# The name's cells become the run's own copy of map number +which+ of the maps of the declaration
# up now, as that map was declared (Reference#mutable_map, and the copy in #exec_show_map).
def rg_copy_map(background, which)
  up = rg_declaration_up(background)
  map = rg_map_entry(up, which)
  count = @rg_game_maps[map + RG_MAP_COLS] * @rg_game_maps[map + RG_MAP_ROWS]
  first = @rg_game_maps[map + RG_MAP_CELLS]
  @rg_cells_now[rg_keeper_of(background)] = [which, @rg_game_map_cells[first, count], up]
end

# Each background with the name is drawn from its own first map again, as declared.
def rg_forget_own_cells(background)
  @rg_cells_now[rg_keeper_of(background)] = [0, nil, 0]
end

# The start of Reference#take_over: a background coming up as a scene takes over goes up as
# declared, so the cells the game changed of its name are forgotten before anything is painted.
def rg_background_forget_cells(background) = rg_forget_own_cells(background)

def rg_run_field(run, field) = @rg_game_tile_runs[(RG_RUN_FIELDS * run) + field]

# Every run's painted places, one after another, made the first time they are asked for; and where
# this run's start among them.
def rg_painted_places
  @rg_painted_places ||= Array.new(@rg_game_picture_sizes[RG_SIZE_RUN_PIXELS] + 1, 0)
end

# One pixel of a cell's tile, or RG_SEE_THROUGH (Reference#background_pixel), in the colors the
# background is drawn with now (Reference#tile_colors): its tiles as drawn with each step come one
# whole set after another. A tile the game paints is read from what it last copied in, and shown in
# its run's colors as the background is drawn with them now.
def rg_tile_pixel(background, cell, tx, ty)
  painted = rg_background_field(background, RG_BG_PAINTED)
  if painted != RG_NOT_PAINTED && @rg_game_painted_tiles[painted + (2 * cell)] != RG_NOT_PAINTED
    run = @rg_game_painted_tiles[painted + (2 * cell)]
    which = @rg_game_painted_tiles[painted + (2 * cell) + 1]
    place = rg_painted_places[rg_run_field(run, RG_RUN_PLACES) + (which * RG_RUN_TILE_PIXELS) + (ty * RG_RUN_TILE_SIDE) + tx]
    set = (rg_tile_set_now(background) * @rg_game_picture_sizes[RG_SIZE_RUNS]) + run
    return @rg_game_run_colors[rg_background_field(background, RG_BG_RUN_COLORS) + (set * RG_PLACES_IN_RUN_COLORS) + place]
  end
  tile_w = rg_background_field(background, RG_BG_TILE_W)
  tile_h = rg_background_field(background, RG_BG_TILE_H)
  tile = (rg_tile_set_now(background) * rg_background_field(background, RG_BG_TILES)) + cell
  @rg_game_tile_pixels[rg_background_field(background, RG_BG_TILES_START) + (tile * tile_w * tile_h) + (ty * tile_w) + tx]
end

# Reference#stamp_background: the whole map onto the picture, cell by cell.
def rg_background_stamp(background)
  # Reference#stamp_background: a status bar is painted from its own top as the view is built.
  return rg_request_repaint if rg_bar?(background)


  tile_w = rg_background_field(background, RG_BG_TILE_W)
  tile_h = rg_background_field(background, RG_BG_TILE_H)
  rg_mix_as_layer(rg_background_field(background, RG_BG_SEE_THROUGH))
  rg_map_rows(background).times do |row|
    rg_map_cols(background).times do |col|
      cell = rg_map_cell(background, row, col)
      next if cell < 0

      tile_h.times do |ty|
        tile_w.times do |tx|
          color = rg_tile_pixel(background, cell, tx, ty)
          rg_set_pixel((col * tile_w) + tx, (row * tile_h) + ty, color) if color != RG_SEE_THROUGH
        end
      end
    end
  end
  rg_mix_nothing
end

# Reference#request_repaint: a rebuild of the whole view is owed, and painted when something needs
# the picture. A painted screen is never built again, in a game that also has screens drawn from
# tiles: its picture is whatever the game painted there, and building the view from scenery would
# wipe it.
def rg_request_repaint
  return if @rg_kind == RG_BITMAP && @rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE] != 0

  rg_forget_expired_corners
  @rg_rebuild_pending = true
  rg_keep_shares_for_pending_rebuild
end

# Reference#exec_scroll_rows, and anything else that changes the picture without painting it.
def rg_screen_request_rebuild = rg_request_repaint

# Reference#painted_screen?: is the screen that is up one the game paints? To the display that is a
# single background, whatever was painted on it, so it goes into blocks whole, as it is read.
def rg_painted_screen? = @rg_kind < 0 || @rg_kind == RG_BITMAP

# Reference#exec_pixelate. The size is read as the picture is next built, or as a painted screen
# is next read, so the picture is owed again only when the size is a different one.
def rg_screen_pixelate(size)
  held_to = rg_clamp_wide(size, 1, @rg_game_picture_sizes[RG_SIZE_LARGEST_BLOCK])
  return if held_to == @rg_block

  @rg_block = held_to
  if rg_painted_screen?
    @rg_read_block = @rg_block
  else
    rg_request_repaint
  end
end

# Reference#exec_see_through: the amounts have been worked out again for the frame about to be
# drawn, and the picture is owed when they come to other sixteenths than the ones last told.
def rg_see_through_told(layer)
  now = rg_shares_now(layer)
  return if @rg_told_shares[layer] == now

  @rg_told_shares[layer] = now
  rg_request_repaint
end

def rg_stack_place(background) = rg_background_field(background, RG_BG_STACK_PLACE)

# Reference#behind?: only when both named a layer.
def rg_behind?(a, b)
  rg_stack_place(a) != RG_NO_LAYER && rg_stack_place(b) != RG_NO_LAYER && rg_stack_place(a) < rg_stack_place(b)
end

# Whether an entry of the list is among those being put in order: every one, or (+over+ a
# background) only the ones a named layer puts in front of it.
def rg_in_order_asked?(entry, over) = over < 0 || rg_behind?(over, entry)

# Where the LAST entry for +background+ lands once the entries asked for are put in the order the
# stack asks for (IR::Stacking.order_by_stack), counting from 0 among them, or -1 when it has no
# entry. An entry that named no layer stays where it is. The ones that did are sorted by how far
# forward their layers are — two in one layer keeping the order they came in — and handed, in that
# order, the places the named entries held.
def rg_last_place_in_stack_order(background, over)
  place = rg_stack_place(background)
  at = -1
  last = -1
  further_back = 0
  in_its_layer = 0
  in_its_layer_by_last = 0
  @rg_shown_backgrounds.each do |entry|
    next unless rg_in_order_asked?(entry, over)

    at += 1
    entry_place = rg_stack_place(entry)
    further_back += 1 if entry_place != RG_NO_LAYER && entry_place < place
    in_its_layer += 1 if entry_place != RG_NO_LAYER && entry_place == place
    if entry == background
      last = at
      in_its_layer_by_last = in_its_layer
    end
  end
  return last if last < 0 || place == RG_NO_LAYER

  # It is the named entry number +nth+ in sorted order, so it takes the place of the named entry
  # number +nth+ in the order they went up.
  nth = further_back + in_its_layer_by_last - 1
  named = -1
  at = -1
  @rg_shown_backgrounds.each do |entry|
    next unless rg_in_order_asked?(entry, over)

    at += 1
    if rg_stack_place(entry) != RG_NO_LAYER
      named += 1
      return at if named == nth
    end
  end
  -1
end

# Reference#in_stack_order over the scenery that is up — all of it, or the part a named layer puts
# in front of +over+ — with each one stamped in that order. Stamping one again paints over every
# stamp of it before, so only where the last entry for each background lands decides the picture,
# and each is stamped once, in the order of those places.
def rg_stamp_in_stack_order(over)
  return if over >= 0 && rg_stack_place(over) == RG_NO_LAYER

  lands = Array.new(@rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]) { |bg| rg_last_place_in_stack_order(bg, over) }
  loop do
    nxt = -1
    lands.each_index { |bg| nxt = bg if lands[bg] >= 0 && (nxt < 0 || lands[bg] < lands[nxt]) }
    return if nxt < 0

    rg_background_stamp(nxt)
    lands[nxt] = -1
  end
end

# Reference#put_up_background. A stamp only covers where it has solid pixels, so a background a
# named layer puts BEHIND one already up would land in front of it; the ones it belongs behind are
# stamped again over it. A turned background is painted through its turn at the next rebuild.
def rg_background_put_up(background)
  rg_forget_own_cells(background) if rg_background_field(background, RG_BG_ON_ARRIVAL) != 0
  @rg_shown_backgrounds << background
  rg_mark_from_corner(background)
  @rg_scenery_kept = false
  return rg_request_repaint if @rg_turns[rg_keeper_of(background)].turned || rg_bar?(background) || rg_bar_showing

  rg_background_stamp(background)
  rg_stamp_in_stack_order(background)
end

# Reference#exec_affine_background: the angle wraps into 0..359 as Ruby's % does.
def rg_background_turn(background, angle, size, pivot_x, pivot_y)
  @rg_turns[rg_keeper_of(background)] = RgTurn.new(true, angle % 360, size, pivot_x, pivot_y)
  rg_request_repaint
end

# Reference#showing_scenery: scenery every screen shows, and the running scene's own.
def rg_showing?(background)
  scene = rg_background_field(background, RG_BG_SCENE)
  scene == RG_EVERY_SCENE || scene == @rg_scene
end

# Reference#exec_in_loop: while +on+ is not nought, the end of a pass is placing the frame's writes,
# and a background that pass put up still shows from its corner.
def rg_screen_placing_at_pass_end(on)
  @rg_placing_at_pass_end = on != 0
end

# Reference#exec_scroll_background
def rg_background_scroll(background, x, y)
  keeper = rg_keeper_of(background)
  @rg_scrolls[keeper] = [x, y]
  @rg_from_corner[keeper] = false unless @rg_placing_at_pass_end
  rg_request_repaint
end

# Whether a background is a status bar (RG_BG_BAR_TOP).
def rg_bar?(background) = rg_background_field(background, RG_BG_BAR_TOP) != RG_NOT_A_BAR

# Reference#exec_place_bar
def rg_place_bar(background, top)
  keeper = rg_keeper_of(background)
  @rg_bar_tops[keeper] = rg_clamp_wide(top, 0, RG_SCREEN_HEIGHT)
  @rg_bar_placed[keeper] = true
  @rg_from_corner[keeper] = false unless @rg_placing_at_pass_end
  rg_request_repaint
end

# Reference#bar_top_shown
def rg_bar_top_shown(bar)
  declared = rg_clamp_wide(rg_background_field(bar, RG_BG_BAR_TOP), 0, RG_SCREEN_HEIGHT)
  keeper = rg_keeper_of(bar)
  @rg_from_corner[keeper] || !@rg_bar_placed[keeper] ? declared : @rg_bar_tops[keeper]
end

# Reference#bar_showing: the status bar on screen, or nil.
def rg_bar_showing
  @rg_game_picture_sizes[RG_SIZE_BACKGROUNDS].times.find { |bg| rg_showing?(bg) && rg_bar?(bg) }
end

# Reference#scenery_rows
def rg_scenery_rows
  bar = rg_bar_showing
  bar ? rg_bar_top_shown(bar) : RG_SCREEN_HEIGHT
end

# Reference#paint_status_bar: from its top row to the bottom of the screen, its map from its own
# corner, never scrolled; past the end of its map the backdrop stays.
def rg_paint_status_bar(bar)
  top = rg_bar_top_shown(bar)
  (top...RG_SCREEN_HEIGHT).each { |py| rg_paint_map_row(bar, py - top, 0, nil, py) }
end

# Reference#exec_set_tile: the copy is made even when the cell turns out not to be there. A cell is
# kept as a signed sixteen-bit number, as the map's cells are.
def rg_background_set_tile(background, col, row, tile)
  # A tile only another scene's declaration of the name has changes nothing here.
  return if tile >= rg_background_field(rg_declaration_up(background), RG_BG_TILES)

  keeper = rg_keeper_of(background)
  rg_copy_map(background, 0) unless @rg_cells_now[keeper][1]
  return unless rg_in_map?(background, row, col)

  cells = @rg_cells_now[keeper][1]
  place = rg_cell_place(background, row, col)
  return if cells[place] == tile

  cells[place] = rg_to_half(tile)
  rg_request_repaint
end

# Reference#exec_show_map: of the maps of the declaration up now.
def rg_background_show_map(background, which)
  return if which < 0 || which >= rg_background_field(rg_declaration_up(background), RG_BG_SHOWABLE_MAPS)

  rg_copy_map(background, which)
  rg_request_repaint
end

# Where choice number +which+ is in a row that holds a thing's own first and then +others+ more: a
# number naming none of the others is its own.
def rg_place_of_choice(which, others) = which >= 0 && which < others ? which + 1 : 0

# Reference#exec_background_colors: the next rebuild reads the tiles in the colors named. The number
# is kept for the name, and what it names is worked out for each entry as it is drawn
# (rg_tile_set_now).
def rg_background_draw_with(background, which)
  @rg_colors_told[rg_keeper_of(background)] = which.negative? ? 0 : which + 1
  rg_request_repaint
end

# Framebuffer#paint_row, a cell at a time: one color of scenery laid on the picture at (px, py),
# which is on the screen, mixed and faded as whatever is in force says.
def rg_lay_scenery(px, py, color)
  at = (py * RG_SCREEN_WIDTH) + px
  painted = rg_into_cell(color, @rg_pixels[at], @rg_pixels, at)
  @rg_pixels[at] = painted
  @rg_picture_without_sprites[at] = painted if rg_sprites_seen_through?
end

# The row of the picture that screen row +py+ is drawn from: its own, or the row at the top of its
# block while a background is being painted for blocks.
def rg_row_drawn_from(py) = py - (py % @rg_rows_tall)

def rg_bend_asked(background) = background == @rg_asked_bend[0] ? 1 : 0
def rg_bend_line = @rg_asked_bend[1]

def rg_bend_answer(offset)
  @rg_asked_bend[2] = offset
end

# Reference#run_bend_for_row: the game asked how far across line +py+ of the background that keeps
# the name sits, after running whatever its block says to run.
def rg_run_bend_for_line(keeper, py)
  @rg_asked_bend[0] = keeper
  @rg_asked_bend[1] = py
  rg_game_bend_offsets
  @rg_asked_bend[0] = RG_NOBODY_ASKED
  @rg_asked_bend[2]
end

# Lines +first_line+ up to +past_line+ of one background, worked out in turn and kept.
def rg_bend_work_out(background, first_line, past_line)
  keeper = rg_keeper_of(background) # the game answers for the name
  lines = @rg_bend_lines[keeper] ||= Array.new(RG_SCREEN_HEIGHT, 0)
  (first_line...past_line).each { |py| lines[py] = rg_run_bend_for_line(keeper, py) }
end

# Reference#work_out_bends, last in every frame boundary of a game that bends a background it has:
# every bend's lines are worked out, and the picture is owed again.
def rg_screen_work_out_bends
  rg_game_work_out_bends
  rg_request_repaint
end

# Reference#bend_offset_at: how far across line +py+ of the screen a background sits, on top of its
# scroll, as the gap between frames last worked it out. Before the first gap: flat for a game that
# waits for the screen, and worked out as the line is painted for one that never waits. Nought for
# a background the game does not bend.
def rg_bend_at(background, py)
  return 0 if rg_background_field(background, RG_BG_BENT) == 0

  keeper = rg_keeper_of(background)
  lines = @rg_bend_lines[keeper]
  return lines[py] if lines

  @rg_frames_begun ? 0 : rg_run_bend_for_line(keeper, py)
end

# Reference#paint_streamed_background_window: a background with a map too big for any grid, or with
# maps of different sizes, does not come round again: past any edge of its map there are no cells.
def rg_paint_window_without_wrapping(background)
  map_h = rg_map_rows(background) * rg_background_field(background, RG_BG_TILE_H)
  scroll_x, scroll_y = rg_scroll_shown(background)
  rg_scenery_rows.times do |py|
    my = scroll_y + rg_row_drawn_from(py)
    next if my < 0 || my >= map_h

    rg_paint_map_row(background, my, scroll_x + rg_bend_at(background, py), nil, py)
  end
end

# ONE ROW OF THE SCREEN FROM ONE ROW OF A BACKGROUND'S MAP (Reference#paint_background_window, a row
# at a time): the screen's pixel px shows map column off_x + px, taken round at +wrap_w+ where the
# map wraps, or not at all (nil) where it does not. +my+ is not below nought. Where the map has no
# cell or no tile, or the tile is see-through, what is behind stays.
#
# Which map is up, how big it is, its tiles' size and the tile set in use cannot change while a row
# is painted, so they are asked once here, and a cell is looked up once for each tile the row
# crosses rather than for each pixel. A painted tile is read the slow way (rg_tile_pixel), since
# where its pixels are depends on the cell.
#
# What this asks of the background is rg_map_cell and rg_tile_pixel written out, and so is what
# rg_paint_turned_window asks; and the plain pixel it lays is rg_lay_scenery's. A change to how
# cells, tile sets or a laid pixel are kept changes those three places too. The checked run holds
# all of it to the interpreter, pixel for pixel.
def rg_paint_map_row(background, my, off_x, wrap_w, py)
  tile_w = rg_background_field(background, RG_BG_TILE_W)
  tile_h = rg_background_field(background, RG_BG_TILE_H)
  keeper = rg_keeper_of(background)
  map = rg_map_now(background)
  cols = @rg_game_maps[map + RG_MAP_COLS]
  row = my / tile_h
  return if row >= @rg_game_maps[map + RG_MAP_ROWS]

  own = @rg_cells_now[keeper][1]
  cells = own || @rg_game_map_cells
  first = (own ? 0 : @rg_game_maps[map + RG_MAP_CELLS]) + (row * cols)
  ty = my % tile_h
  tile_size = tile_w * tile_h
  set_start = rg_background_field(background, RG_BG_TILES_START) +
              (rg_tile_set_now(background) * rg_background_field(background, RG_BG_TILES) * tile_size) + (ty * tile_w)
  painted = rg_background_field(background, RG_BG_PAINTED)
  painted_tiles = @rg_game_painted_tiles
  pixels = @rg_game_tile_pixels
  sheet = @rg_onto_sheet ? @rg_sheet : nil
  sheet_row = py * RG_SCREEN_WIDTH
  # With no fade painted in and no see-through layer being mixed, rg_lay_scenery comes to storing
  # the color, marking the cell as no mix and keeping it in the picture without sprites where
  # that is kept; so that is done here.
  plain = !@rg_fading_what_is_painted && !@rg_mixing
  picture = @rg_pixels
  mixed_cells = @rg_picture_mixes.is_mixed
  without_sprites = rg_sprites_seen_through? ? @rg_picture_without_sprites : nil
  # A tile's width of the row at a time: the screen pixels from px that show one tile's row, which
  # end at the tile's right edge or the screen's. Where the map wraps it wraps at a whole number of
  # tiles, so a tile is never cut by the wrap.
  px = 0
  while px < RG_SCREEN_WIDTH
    mx = off_x + px
    mx %= wrap_w if wrap_w
    if mx < 0 # only where the map does not wrap: nothing until the map's left edge
      px -= mx
      next
    end
    col = mx / tile_w
    tx = mx - (col * tile_w)
    run = tile_w - tx
    run = RG_SCREEN_WIDTH - px if run > RG_SCREEN_WIDTH - px
    cell = col < cols ? cells[first + col] : RG_CELL_EMPTY
    if cell >= 0
      slow = painted != RG_NOT_PAINTED && painted_tiles[painted + (2 * cell)] != RG_NOT_PAINTED
      from = set_start + (cell * tile_size) + tx
      i = 0
      while i < run
        color = slow ? rg_tile_pixel(background, cell, tx + i, ty) : pixels[from + i]
        if color != RG_SEE_THROUGH
          at = sheet_row + px + i
          if sheet
            sheet[at] = color
          elsif plain
            color &= 0xFFFF
            picture[at] = color
            mixed_cells[at] = 0
            without_sprites[at] = color if without_sprites
          else
            rg_lay_scenery(px + i, py, color)
          end
        end
        i += 1
      end
    end
    px += run
  end
end

# Reference#paint_background_window, for a background never turned: the window sits where the
# background is scrolled to, the map wraps over the console's whole grid, and a row or cell past the
# map shows what is behind.
def rg_paint_window(background)
  return rg_paint_window_without_wrapping(background) if rg_background_field(background, RG_BG_NEVER_WRAPS) != 0

  map = rg_map_now(background)
  map_w = @rg_game_maps[map + RG_MAP_GRID_COLS] * rg_background_field(background, RG_BG_TILE_W)
  map_h = @rg_game_maps[map + RG_MAP_GRID_ROWS] * rg_background_field(background, RG_BG_TILE_H)
  return if map_w == 0 || map_h == 0

  scroll_x, scroll_y = rg_scroll_shown(background)
  off_y = scroll_y % map_h
  rg_scenery_rows.times do |py|
    off_x = (scroll_x + rg_bend_at(background, py)) % map_w
    my = (off_y + rg_row_drawn_from(py)) % map_h
    rg_paint_map_row(background, my, off_x, map_w, py)
  end
end

# IR::Affine.matrix: one over the size, held at the largest number the matrix holds; then the sine
# table, cos d being sin(d + 90). The numbers come from @rg_game_turn_rules, which the build writes
# from Ruby's own. Gives back [cos, sin].
def rg_affine_matrix(angle, size)
  scale_one, one_th, most, least_size = @rg_game_turn_rules
  scale = size < least_size ? least_size : size
  recip = (scale_one * one_th) / scale
  recip = most if recip > most
  [(@rg_game_sines[angle + 90] * recip) / one_th, (@rg_game_sines[angle] * recip) / one_th]
end

# Reference#paint_affine_background_window: for each screen pixel, work back through the turn to
# the map pixel that lands there, from wherever the background is scrolled to.
def rg_paint_turned_window(background)
  tile_w = rg_background_field(background, RG_BG_TILE_W)
  tile_h = rg_background_field(background, RG_BG_TILE_H)
  map = rg_map_now(background)
  map_w = @rg_game_maps[map + RG_MAP_GRID_COLS] * tile_w
  map_h = @rg_game_maps[map + RG_MAP_GRID_ROWS] * tile_h
  return if map_w == 0 || map_h == 0

  keeper = rg_keeper_of(background)
  turn = @rg_turns[keeper]
  one_th = @rg_game_turn_rules[1]
  turn_cos, turn_sin = rg_affine_matrix(turn.angle, turn.size)
  # A turned layer is placed by its turn, which putting it up leaves as it is.
  scroll_x, scroll_y = @rg_scrolls[keeper]
  pivot_x = turn.pivot_x
  pivot_y = turn.pivot_y
  # What rg_map_cell and rg_tile_pixel ask of the background, asked once: nothing the game does
  # runs while a turned layer is painted, so none of it can change (see rg_paint_map_row).
  cols = @rg_game_maps[map + RG_MAP_COLS]
  rows = @rg_game_maps[map + RG_MAP_ROWS]
  own = @rg_cells_now[keeper][1]
  cells = own || @rg_game_map_cells
  first = own ? 0 : @rg_game_maps[map + RG_MAP_CELLS]
  tile_size = tile_w * tile_h
  set_start = rg_background_field(background, RG_BG_TILES_START) +
              (rg_tile_set_now(background) * rg_background_field(background, RG_BG_TILES) * tile_size)
  painted = rg_background_field(background, RG_BG_PAINTED)
  painted_tiles = @rg_game_painted_tiles
  pixels = @rg_game_tile_pixels
  sheet = @rg_onto_sheet ? @rg_sheet : nil
  rg_scenery_rows.times do |py|
    dy = rg_row_drawn_from(py) - pivot_y
    # The row's part of each sum, the same for every pixel of the row.
    row_part_x = (turn_sin * dy)
    row_part_y = (turn_cos * dy)
    last_row = -1
    last_col = -1
    cell = RG_CELL_EMPTY
    start = 0
    slow = false
    px = 0
    while px < RG_SCREEN_WIDTH
      dx = px - pivot_x
      mx = (scroll_x + pivot_x + (((turn_cos * dx) + row_part_x) / one_th)) % map_w
      my = (scroll_y + pivot_y + (((-turn_sin * dx) + row_part_y) / one_th)) % map_h
      row = my / tile_h
      col = mx / tile_w
      if row != last_row || col != last_col
        last_row = row
        last_col = col
        cell = row < rows && col < cols ? cells[first + (row * cols) + col] : RG_CELL_EMPTY
        if cell >= 0
          slow = painted != RG_NOT_PAINTED && painted_tiles[painted + (2 * cell)] != RG_NOT_PAINTED
          start = set_start + (cell * tile_size)
        end
      end
      if cell >= 0
        tx = mx % tile_w
        ty = my % tile_h
        color = slow ? rg_tile_pixel(background, cell, tx, ty) : pixels[start + (ty * tile_w) + tx]
        if color != RG_SEE_THROUGH
          if sheet
            sheet[(py * RG_SCREEN_WIDTH) + px] = color
          else
            rg_set_pixel(px, py, color)
          end
        end
      end
      px += 1
    end
  end
end

# Reference#paint_background_window: one background painted where it sits in the view.
def rg_paint_background(background)
  if @rg_turns[rg_keeper_of(background)].turned
    rg_paint_turned_window(background)
  else
    rg_paint_window(background)
  end
end

# Reference#paint_scenery_in_blocks: ONE BACKGROUND IN BLOCKS, by the display's own rule. The
# blocks are fixed to the screen, and each shows the color the background has at the block's top
# left corner. Down and across are done apart, because a display draws a row at a time: the
# background goes onto the sheet rows first, every row of a block drawn from the map row its top
# row shows and still placed by its own bend, and is laid on the picture through the blocks across.
# A background that can turn is left one pixel wide at a size of two, so its rows double and its
# columns do not: the emulator's rule, kept because the console's picture is checked against it.
def rg_paint_scenery_in_blocks(background)
  @rg_sheet.fill(RG_NOTHING_ON_SHEET)
  @rg_onto_sheet = true
  @rg_rows_tall = @rg_block
  rg_paint_background(background)
  @rg_onto_sheet = false
  @rg_rows_tall = 1
  wide = rg_background_field(background, RG_BG_CAN_TURN) != 0 && @rg_block == 2 ? 1 : @rg_block
  rg_scenery_rows.times do |py|
    RG_SCREEN_WIDTH.times do |px|
      color = @rg_sheet[(py * RG_SCREEN_WIDTH) + px - (px % wide)]
      rg_lay_scenery(px, py, color) if color != RG_NOTHING_ON_SHEET
    end
  end
end

# Reference#paint_scenery
def rg_paint_scenery(background)
  if @rg_block > 1 && rg_background_field(background, RG_BG_IN_BLOCKS) != 0
    rg_paint_scenery_in_blocks(background)
  else
    rg_paint_background(background)
  end
end

# --- sprites ---

# One picture: its pixels, where they start among them, and its size — [pixels, start, width,
# height]. A painted image's pixels are its own, from 0; any other is in @rg_game_image_pixels.
def rg_picture_of(image)
  info = RG_IMAGE_FIELDS * image
  painted = @rg_painted_images && @rg_painted_images[image]
  width = @rg_game_images[info + 1]
  height = @rg_game_images[info + 2]
  painted ? [painted, 0, width, height] : [@rg_game_image_pixels, @rg_game_images[info], width, height]
end

# Reference#run_tile_places: the 64 places of tile +which+ of a run's list, row by row. Each byte
# is two pixels, the left one in its low four bits; a byte the list does not hold reads as 0.
def rg_read_tile_places(list, which, places, into)
  (RG_RUN_TILE_PIXELS / 2).times do |at|
    index = (which * (RG_RUN_TILE_PIXELS / 2)) + at
    byte = index < rg_list_length(list) ? rg_list_get(list, index) & 0xFF : 0
    places[into + (2 * at)] = byte & 0x0F
    places[into + (2 * at) + 1] = byte >> 4
  end
end

# Reference#copy_run_tiles. A run a background shows takes its tiles one after another. A run that
# is a sprite's picture has its tiles in the order a sprite's are kept, left to right and then top
# to bottom, and they are laid back out into the one picture (#copy_run_picture); then every image
# that is that picture is made again from it, each in its own colors.
def rg_tiles_copy(run, list)
  places = rg_painted_places
  first = rg_run_field(run, RG_RUN_PLACES)
  width = rg_run_field(run, RG_RUN_WIDTH)
  height = rg_run_field(run, RG_RUN_HEIGHT)
  if width == 0
    rg_run_field(run, RG_RUN_TILES).times { |which| rg_read_tile_places(list, which, places, first + (which * RG_RUN_TILE_PIXELS)) }
    return
  end
  across = width / RG_RUN_TILE_SIDE
  tile = Array.new(RG_RUN_TILE_PIXELS, 0)
  (across * (height / RG_RUN_TILE_SIDE)).times do |which|
    rg_read_tile_places(list, which, tile, 0)
    left = (which % across) * RG_RUN_TILE_SIDE
    top = (which / across) * RG_RUN_TILE_SIDE
    RG_RUN_TILE_PIXELS.times do |i|
      places[first + ((top + (i / RG_RUN_TILE_SIDE)) * width) + left + (i % RG_RUN_TILE_SIDE)] = tile[i]
    end
  end
  @rg_painted_images ||= Array.new(@rg_game_picture_sizes[RG_SIZE_IMAGES] + 1)
  rg_run_field(run, RG_RUN_IMAGES).times do |i|
    shown_as = (rg_run_field(run, RG_RUN_FIRST_IMAGE) + i) * RG_RUN_IMAGE_FIELDS
    image = @rg_game_run_images[shown_as]
    @rg_painted_images[image] = Array.new(width * height) { |at| rg_to_half(@rg_game_run_images[shown_as + 1 + places[first + at]]) }
  end
end

# Reference#blit_image: a see-through pixel is skipped, and each other one goes on as stored.
def rg_blit_image(image, x, y)
  art, start, width, height = rg_picture_of(image)
  height.times do |row|
    width.times do |col|
      color = art[start + (row * width) + col]
      rg_set_pixel(x + col, y + row, color) if color != RG_NOT_DRAWN
    end
  end
end

# The screen row the box row +row+ of a turned sprite lands on when the box's first row is at
# +top+, or -1 for a line below the screen, where the box stands unseen (Reference::TurnedBox): the
# display counts the rows of a sprite's box in lines that come round, and the screen is fewer.
def rg_turned_box_line(top, row)
  line = (top + row) % RG_TURNED_BOX_LINES
  line < RG_SCREEN_HEIGHT ? line : -1
end

# TurnedBox.rows_shown's first test, with Affine.rows_reached: a sprite is drawn at all only while
# some of the rows its picture can reach are on the screen. A picture that +resizes+ can fill its
# whole box; one that only turns stays within a square as wide as its diagonal, and a pixel each
# side, about the middle.
def rg_turned_box_on_screen?(top, width, height, resizes)
  first = 0
  past = height * 2
  if resizes == 0
    reach = Integer.sqrt((width * width) + (height * height)) + 2
    first = height - (reach / 2)
    past = first + reach
  end
  top + past > 0 && top + first < RG_SCREEN_HEIGHT
end

# Reference#blit_image_transformed: a picture turned +angle+ degrees clockwise and drawn at +size+,
# about its own middle, its top left as drawn at (x, y). The console walks the patch of screen the
# sprite can cover — twice the picture each way, centered on it — and for each pixel works BACK
# through the turn to the pixel of the picture that lands there; one that falls outside the picture
# is not drawn. A screen pixel is taken at its whole coordinate and the answer rounded down.
def rg_blit_image_turned(image, x, y, angle, size, resizes)
  art, start, width, height = rg_picture_of(image)
  one_th = @rg_game_turn_rules[1]
  turn_cos, turn_sin = rg_affine_matrix(angle % 360, size)
  left = x - (width / 2)
  top = y - (height / 2)
  return unless rg_turned_box_on_screen?(top, width, height, resizes)

  (height * 2).times do |iy|
    line = rg_turned_box_line(top, iy)
    next if line < 0

    dy = iy - height
    (width * 2).times do |ix|
      dx = ix - width
      from_x = (((turn_cos * dx) + (turn_sin * dy)) / one_th) + (width / 2)
      from_y = (((-turn_sin * dx) + (turn_cos * dy)) / one_th) + (height / 2)
      next if from_x < 0 || from_x >= width || from_y < 0 || from_y >= height

      color = art[start + (from_y * width) + from_x]
      rg_set_pixel(left + ix, line, color) if color != RG_NOT_DRAWN
    end
  end
end

# Reference#draw_object and #paint_snapshot_object
def rg_draw_placed(placed)
  if placed.turned
    rg_blit_image_turned(placed.image, placed.x, placed.y, placed.angle, placed.size, placed.resizes)
  else
    rg_blit_image(placed.image, placed.x, placed.y)
  end
end

# --- a sprite in blocks (Reference::SpriteBlocks, which holds the rule and says why) ---
#
# The blocks are fixed to the screen, as a background's are. What differs is where a block takes
# its color from, because a sprite is a small box and a block need not start inside it.

# SpriteBlocks#block_start and #round_up: where the block a column or row is in starts, and the end
# of the block an edge falls in.
def rg_block_start(at) = at - (at % @rg_block)
def rg_block_end(edge) = -((-edge) / @rg_block) * @rg_block

# Reference#picture_reader: what a picture shows at a column and row of itself, or RG_NOT_DRAWN
# where it is see-through and anywhere outside it.
def rg_picture_color(picture, col, row)
  art, start, width, height = picture
  return RG_NOT_DRAWN if col < 0 || col >= width || row < 0 || row >= height

  art[start + (row * width) + col]
end

# SpriteBlocks#paint_box: one box of a sprite whose picture's corner is at (x, y), the box's own
# corner at (left, top) on the screen. A block that starts left of the box or above it shows the
# box's first column or row; the last block across is drawn whole, past the box's right edge;
# nothing is drawn past its bottom edge.
def rg_paint_box_in_blocks(picture, x, y, left, top, width, height)
  first_row = top > 0 ? top : 0
  past_row = top + height < RG_SCREEN_HEIGHT ? top + height : RG_SCREEN_HEIGHT
  first_col = left > 0 ? left : 0
  past_col = rg_block_end(left + width)
  past_col = RG_SCREEN_WIDTH if past_col > RG_SCREEN_WIDTH
  (first_row...past_row).each do |py|
    from_y = rg_clamp_wide(rg_block_start(py), top, top + height - 1)
    (first_col...past_col).each do |px|
      color = rg_picture_color(picture, rg_clamp_wide(rg_block_start(px), left, left + width - 1) - x, from_y - y)
      rg_set_pixel(px, py, color) if color != RG_NOT_DRAWN
    end
  end
end

# SpriteBlocks#paint_upright: a sprite that stands upright, a box at a time, back to front, so where
# one box's last block runs over the next the one in front wins. The boxes are the ones listed for
# the picture it shows (@rg_game_sprite_boxes).
def rg_paint_upright_in_blocks(placed)
  listed = @rg_game_sprite_blocks[placed.sprite]
  pictures = @rg_game_sprite_boxes[listed]
  listed += 1
  showing = @rg_game_image_pictures[placed.image]
  pictures.times do
    name = @rg_game_sprite_boxes[listed]
    boxes = @rg_game_sprite_boxes[listed + 1]
    box = listed + 2
    listed = box + (4 * boxes)
    next if name != showing

    picture = rg_picture_of(placed.image)
    (boxes - 1).downto(0) do |b|
      at = box + (4 * b)
      rg_paint_box_in_blocks(picture, placed.x, placed.y, placed.x + @rg_game_sprite_boxes[at],
                             placed.y + @rg_game_sprite_boxes[at + 1], @rg_game_sprite_boxes[at + 2],
                             @rg_game_sprite_boxes[at + 3])
    end
    return
  end
  rg_fault("sprite #{placed.sprite} is shown in blocks and has no boxes for the picture it shows")
end

# SpriteBlocks#turned_row: the row of its box a turned sprite shows on screen row +py+, which is the
# row at the top of the block, held to the box's first row when the block began above it, worked
# out as the display counts, in lines that come round.
def rg_turned_row(py, top, height)
  first = top % RG_TURNED_BOX_LINES
  past = first + height
  line = rg_block_start(py)
  line = first if line < first && first < RG_SCREEN_HEIGHT
  line = past - 1 if line >= past % RG_TURNED_BOX_LINES
  (line - first) % RG_TURNED_BOX_LINES
end

# SpriteBlocks#paint_turned: a sprite that turns or resizes, drawn in a box twice its picture's size
# about the picture's middle. A block that starts left of the box shows what the turned picture
# would show ONE COLUMN before the box begins; one that starts above it shows the box's first row;
# and the last block across is drawn whole.
def rg_paint_turned_in_blocks(placed)
  picture = rg_picture_of(placed.image)
  width = picture[2]
  height = picture[3]
  one_th = @rg_game_turn_rules[1]
  turn_cos, turn_sin = rg_affine_matrix(placed.angle % 360, placed.size)
  left = placed.x - (width / 2)
  top = placed.y - (height / 2)
  first_col = left > 0 ? left : 0
  past_col = rg_block_end(left + (width * 2))
  past_col = RG_SCREEN_WIDTH if past_col > RG_SCREEN_WIDTH
  return unless rg_turned_box_on_screen?(top, width, height, placed.resizes)

  (height * 2).times do |iy|
    py = rg_turned_box_line(top, iy)
    next if py < 0

    dy = rg_turned_row(py, top, height * 2) - height
    (first_col...past_col).each do |px|
      start = rg_block_start(px)
      dx = (start >= left ? start : left - 1) - left - width
      color = rg_picture_color(picture, (((turn_cos * dx) + (turn_sin * dy)) / one_th) + (width / 2),
                               (((-turn_sin * dx) + (turn_cos * dy)) / one_th) + (height / 2))
      rg_set_pixel(px, py, color) if color != RG_NOT_DRAWN
    end
  end
end

# Reference#paint_snapshot_object: one of the sprites kept for a rebuild, in blocks while the
# picture is shown in them unless the game leaves it as drawn.
def rg_paint_kept_sprite(placed)
  if @rg_block == 1 || @rg_game_sprite_blocks[placed.sprite] == RG_NOT_IN_BLOCKS
    rg_draw_placed(placed)
  elsif placed.turned
    rg_paint_turned_in_blocks(placed)
  else
    rg_paint_upright_in_blocks(placed)
  end
end

def rg_rebuilt_whole? = @rg_game_picture_sizes[RG_SIZE_REBUILT_WHOLE] != 0

# Reference#scene_framebuffer: the backdrop, and every background showing stamped over it. It is a
# picture of its own, so an area the game's drawing is held to does not hold this.
def rg_keep_scenery
  return if @rg_scenery_kept

  outer = @rg_area
  @rg_area = RgArea.new(false, 0, 0, 0, 0)
  @rg_target = @rg_scenery
  rg_clear_to(@rg_backdrop)
  @rg_game_picture_sizes[RG_SIZE_BACKGROUNDS].times { |bg| rg_background_stamp(bg) if rg_showing?(bg) }
  @rg_target = @rg_pixels
  @rg_area = outer
  @rg_scenery_kept = true
end

# Reference#exec_blit
def rg_screen_blit(image, x, y) = rg_blit_image(image, x, y)

# Reference#exec_blit_pose: a number outside the set draws nothing.
def rg_screen_blit_pose(poses, count, pose, x, y)
  rg_blit_image(poses[pose], x, y) if pose >= 0 && pose < count
end

# Reference#exec_draw_column_at: one column of a picture, stretched to +height+ rows. The walk goes
# DOWN THE SCREEN and asks which row of the picture belongs at each screen row, the step held in
# 65536ths of a picture row and cut off at each step — the console's own rule. Only the rows on the
# screen are walked.
def rg_screen_column(image, slice, x, top, height, width)
  return if height <= 0

  art, start, art_width, art_height = rg_picture_of(image)
  column = rg_clamp_wide(slice, 0, art_width - 1)
  step = (art_height << 16) / height
  first = top < 0 ? -top : 0
  past = RG_SCREEN_HEIGHT - top < height ? RG_SCREEN_HEIGHT - top : height
  (first...past).each do |row|
    source = rg_clamp_wide((row * step) >> 16, 0, art_height - 1)
    color = art[start + (source * art_width) + column]
    next if color == RG_NOT_DRAWN

    width.times { |across| rg_set_pixel(x + across, top + row, color) }
  end
end

# The start of Reference#exec_present_objects. A game that draws its sprites straight onto the
# picture has the scenery under them kept from here, as the interpreter does.
def rg_objects_begin
  @rg_drawing = []
  rg_keep_scenery unless rg_rebuilt_whole?
end

def rg_fault_unless_sprite(sprite)
  return if sprite >= 0 && sprite < RG_MAX_SPRITES

  rg_fault("sprite number #{sprite} is not one of the #{RG_MAX_SPRITES} there is room for")
end

# Framebuffer#put_back_cell: the scenery's cell at (x, y) put back on the picture, a mix kept as one
# so that a tint still reaches both its sides.
def rg_put_back_cell(x, y)
  at = (y * RG_SCREEN_WIDTH) + x
  rg_set_pixel(x, y, @rg_scenery[at])
  kept = rg_mixes_of(@rg_target)
  return if !kept || !rg_paintable?(x, y) || @rg_scenery_mixes.is_mixed[at] == 0

  kept.is_mixed[at] = 1
  kept.tops[at] = @rg_scenery_mixes.tops[at]
  kept.unders[at] = @rg_scenery_mixes.unders[at]
end

# Reference#restore_patch: the scenery put back over a patch of the picture.
def rg_restore_patch(left, top, width, height)
  height.times do |row|
    width.times do |col|
      x = left + col
      y = top + row
      rg_put_back_cell(x, y) if rg_on_screen?(x, y)
    end
  end
end

# The same over a turned sprite's patch, each row on the screen row the display counts it at.
def rg_restore_turned_patch(left, top, width, height)
  height.times do |row|
    line = rg_turned_box_line(top, row)
    rg_restore_patch(left, line, width, 1) if line >= 0
  end
end

# Forgets where a sprite was last drawn straight onto the picture, and hands that place over for
# the scenery to be put back there; nil when it is not on the picture.
def rg_forget_drawn_place(sprite)
  rg_fault_unless_sprite(sprite)
  place = @rg_last_drawn[sprite]
  @rg_last_drawn[sprite] = nil
  place
end

# Reference#restore_scene_rect: the scenery put back where this sprite was last drawn. All of a
# sprite's pictures are one size, so any of them says how big the patch is.
def rg_object_take_off(sprite, image)
  place = rg_forget_drawn_place(sprite)
  return unless place

  x, y = place
  _, _, width, height = rg_picture_of(image)
  rg_restore_patch(x, y, width, height)
end

# Reference#restore_scene_rect and #transformed_footprint, for a sprite that turns or resizes. The
# patch has to hold the picture at whatever angle and size it was last drawn. One that only turns
# reaches no further from its middle than half its own diagonal, so a square that wide does; one
# that +resizes+ has no bound short of the whole box the display gives it, twice the picture each
# way. Each row is put back on the screen row it was drawn on.
def rg_object_take_off_turned(sprite, image, resizes)
  place = rg_forget_drawn_place(sprite)
  return unless place

  x, y = place
  _, _, width, height = rg_picture_of(image)
  middle_x = x + (width / 2)
  middle_y = y + (height / 2)
  return rg_restore_turned_patch(middle_x - width, middle_y - height, width * 2, height * 2) if resizes != 0

  side = Integer.sqrt((width * width) + (height * height)) + 2
  rg_restore_turned_patch(middle_x - (side / 2), middle_y - (side / 2), side, side)
end

# One more sprite on screen this frame.
def rg_add_placed(placed)
  rg_fault_unless_sprite(placed.sprite)
  rg_fault("more than #{RG_MAX_SPRITES} sprites on screen at once") if @rg_drawing.length >= RG_MAX_SPRITES
  @rg_drawing << placed
end

def rg_objects_add(sprite, image, x, y, level)
  rg_add_placed(RgPlaced.new(sprite, image, x, y, level, false, 0, 0, 0))
end

def rg_objects_add_turned(sprite, image, x, y, level, angle, size, resizes)
  rg_add_placed(RgPlaced.new(sprite, image, x, y, level, true, angle, size, resizes))
end

# The rest of Reference#exec_present_objects. On a picture that is rebuilt whole, the sprites on
# screen now are kept (#snapshot_object_layer) and the rebuild is owed. On one that is not, each is
# drawn where it is now, and where that was is remembered for taking it off again. Kept whichever
# way the picture is made: a scene taking over later in this pass builds the picture again from it.
def rg_objects_end
  @rg_sprite_layer = @rg_drawing.dup
  return rg_request_repaint if rg_rebuilt_whole?

  @rg_drawing.each do |placed|
    rg_mix_as_sprite(placed.sprite)
    rg_draw_placed(placed)
    rg_mix_nothing
    @rg_last_drawn[placed.sprite] = [placed.x, placed.y]
  end
end

# Reference#sprites: what the game last said is on screen, which stays as it was said from
# rg_objects_end until the next rg_objects_begin: how many, and each by its place among them as
# [whose it is, which picture it shows, x, y].
def rg_screen_drawn_count = @rg_drawing.length

def rg_screen_drawn_sprite(place)
  placed = @rg_drawing[place]
  [@rg_game_sprite_names[placed.sprite], @rg_game_image_pictures[placed.image], placed.x, placed.y]
end

# Which of a row of +count+ things the number +said+ names, read the way the interpreter reads a
# Ruby array: a number below nought counts back from the last. RG_NO_PLACE when it still names
# none, which is where the interpreter stops with an error.
def rg_place_named(said, count)
  place = said < 0 ? said + count : said
  place >= 0 && place < count ? place : RG_NO_PLACE
end

# Reference#names_in_draw_order: the sprite of a run that the order list names next.
def rg_place_in_ordered_run(said, count)
  place = rg_place_named(said, count)
  rg_fault("a draw order names sprite #{said} of the #{count} it puts in order") if place == RG_NO_PLACE
  place
end

# Reference#collision_sprite: the picture a sprite is showing.
def rg_pose_image(poses, count, pose)
  place = rg_place_named(pose, count)
  rg_fault("a sprite is showing picture #{pose} of its #{count}") if place == RG_NO_PLACE
  poses[place]
end

# Reference#pixels_overlap?: do two sprites' drawn pixels touch? Only the rectangle where the two
# boxes overlap is walked.
def rg_pixels_overlap(a_image, a_x, a_y, b_image, b_x, b_y)
  a_art, a_start, a_width, a_height = rg_picture_of(a_image)
  b_art, b_start, b_width, b_height = rg_picture_of(b_image)
  left = a_x > b_x ? a_x : b_x
  top = a_y > b_y ? a_y : b_y
  right = [a_x + a_width, b_x + b_width].min
  bottom = [a_y + a_height, b_y + b_height].min
  (top...bottom).each do |y|
    (left...right).each do |x|
      next if a_art[a_start + ((y - a_y) * a_width) + (x - a_x)] == RG_NOT_DRAWN
      return 1 if b_art[b_start + ((y - b_y) * b_width) + (x - b_x)] != RG_NOT_DRAWN
    end
  end
  0
end

# --- the whole view, rebuilt (Reference#repaint_view) ---

# The fade half of Reference#set_blend_for, for the thing about to be painted: the placed fade in
# force reaches it unless that fade's layer is no further forward than +fade_place+, the furthest
# forward such a layer can be and still leave the thing as drawn. RG_NO_LAYER for a thing every
# placed fade reaches, and for the backdrop. A fade under a layer the game never declared reaches
# everything.
def rg_fade_unless_left_as_drawn(fade_place)
  under = @rg_placed_fade.layer_place
  left_as_drawn = under != RG_NO_LAYER && fade_place != RG_NO_LAYER && fade_place >= under
  @rg_fading_what_is_painted = @rg_placed_fade.in_force && !left_as_drawn
end

def rg_fade_nothing
  @rg_fading_what_is_painted = false
end

def rg_repaint_view
  rg_mix_nothing
  rg_fade_unless_left_as_drawn(RG_NO_LAYER)
  rg_clear_to(@rg_backdrop)
  bar = rg_bar_showing
  if bar
    rg_mix_as_layer(rg_background_field(bar, RG_BG_SEE_THROUGH))
    rg_fade_unless_left_as_drawn(rg_background_field(bar, RG_BG_FADE_PLACE))
    rg_paint_status_bar(bar)
  end
  backgrounds = @rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]
  @rg_game_picture_sizes[RG_SIZE_DEPTHS].times do |level|
    backgrounds.times do |bg|
      next if !rg_showing?(bg) || rg_background_field(bg, RG_BG_LEVEL) != level

      rg_mix_as_layer(rg_background_field(bg, RG_BG_SEE_THROUGH))
      rg_fade_unless_left_as_drawn(rg_background_field(bg, RG_BG_FADE_PLACE))
      rg_paint_scenery(bg)
    end
    @rg_sprite_layer.each do |placed|
      next if placed.level != level

      rg_mix_as_sprite(placed.sprite)
      rg_fade_unless_left_as_drawn(@rg_game_sprite_fade_places[placed.sprite])
      rg_paint_kept_sprite(placed)
    end
  end
  rg_mix_nothing
  rg_fade_nothing
end

# Reference#paint_owed_repaint. Named as the program calls it: every lowering that prints the same
# program calls this name.
def rg_screen_paint_owed_rebuild
  return rg_forget_expired_corners unless @rg_rebuild_pending

  @rg_rebuild_pending = false
  rg_repaint_view
  rg_forget_kept_shares
  rg_forget_expired_corners
end

# --- screens and scenes ---

# A program that waits for frames shows nothing until its first frame is set up.
def rg_screen_hold(value)
  @rg_screen_held = value
end

def rg_screen_frame_started
  @rg_screen_held = 0
  @rg_frames_begun = true
end

# The top of Reference#advance_frame: the corners of the backgrounds this pass put up go once its
# picture is painted. And a frame boundary is the one safe moment to trade the two pages of a
# tear-free screen, so the page just drawn is shown and the game is handed the other — before
# anything can stop the run there.
def rg_screen_frame_ended
  @rg_corners_expired = true if @rg_any_from_corner
  return if @rg_pixels.equal?(@rg_viewed)

  rg_screen_paint_owed_rebuild
  finished = @rg_pixels
  @rg_pixels = @rg_viewed
  @rg_viewed = finished
  @rg_target = @rg_pixels
end

# Reference#exec_screen. Every kind of screen is a display of its own, so any change of kind wipes
# the picture and takes the scenery down; arriving on a screen drawn from tiles puts up again what
# every such screen shows, as declared, and says so (1). A change between one page and two keeps
# the same picture and wipes nothing.
def rg_screen_set(new_kind, two_pages, new_backdrop)
  crossing = @rg_kind >= 0 && @rg_kind != new_kind
  if crossing
    @rg_backdrop = new_backdrop
    rg_clear_to(@rg_backdrop)
    @rg_shown_backgrounds = []
    @rg_scenery_kept = false
  else
    rg_show_backdrop(new_backdrop)
  end
  @rg_kind = new_kind
  rg_show_pages(two_pages)
  @rg_tint_by_display = rg_tint_mixed_by_display? # a tint in force is mixed this screen's way
  @rg_read_block = rg_painted_screen? ? @rg_block : 1 # the size of a block outlasts the screen it was said on
  return 0 if !crossing || new_kind == RG_BITMAP

  @rg_game_picture_sizes[RG_SIZE_ALWAYS_UP].times do |i|
    rg_forget_own_cells(@rg_game_always_up[i])
    rg_background_put_up(@rg_game_always_up[i])
  end
  1
end

# Reference#cross_to_scene_screen
def rg_screen_cross_to(new_kind, two_pages, new_backdrop)
  return rg_screen_set(new_kind, two_pages, new_backdrop) if @rg_kind >= 0 && @rg_kind != new_kind

  rg_show_backdrop(new_backdrop)
  0
end

# rg_screen.c's show_backdrop
def rg_show_backdrop(color)
  return if color == @rg_backdrop

  @rg_backdrop = color
  @rg_scenery_kept = false
  @rg_shown_backgrounds.empty? ? rg_clear_to(@rg_backdrop) : rg_request_repaint
end

def rg_scene_enter(scene)
  @rg_scene = scene
end

# The middle of Reference#take_over, and #take_down_scenery: the last scene's own scenery comes
# down, and the picture goes back to the scenery every screen shows.
def rg_scene_take_down(brings_scenery)
  @rg_scenery_taken_down = false # whether this takeover took any down, which rg_scene_redraw_sprites asks
  any_scene_owned = @rg_shown_backgrounds.any? { |bg| rg_background_field(bg, RG_BG_SCENE) != RG_EVERY_SCENE }
  return if !any_scene_owned && brings_scenery == 0

  rg_screen_paint_owed_rebuild
  kept = @rg_shown_backgrounds.select { |bg| rg_background_field(bg, RG_BG_ON_ARRIVAL) == 0 }
  return if kept.length == @rg_shown_backgrounds.length

  @rg_shown_backgrounds = kept
  @rg_scenery_kept = false
  rg_clear_to(@rg_backdrop)
  rg_stamp_in_stack_order(-1)
  @rg_scenery_taken_down = true
end

# Reference#redraw_sprites_over_arrived_scenery: the sprites of this frame were drawn as it began,
# the leaving scene's among them, and the scenery a scene put up after them covered them. The
# display draws sprites over whatever scenery is up, so the picture is built again from the scenery
# and the sprites kept when they were drawn. A painted screen is left alone. The same for a scene
# that brings none but took the last one's down, which wiped those sprites too.
def rg_scene_redraw_sprites(brings_scenery)
  return if brings_scenery == 0 && !@rg_scenery_taken_down
  return if rg_painted_screen? || @rg_sprite_layer.empty?

  rg_request_repaint
end

# --- reading it back ---

def rg_screen_two_pages = @rg_pixels.equal?(@rg_viewed) ? 0 : 1

# Framebuffer#to_a: the page a viewer is looking at as it is STORED, with no window moved over it
# and no fade or tint mixed in.
def rg_screen_stored
  rg_screen_paint_owed_rebuild
  @rg_viewed
end

# Framebuffer#block_corner: the screen column whose color column +x+ shows while a painted screen is
# read in blocks, which is the first of its block. Across, the blocks are fixed to the screen while
# the picture covers the row from its first column; when the window has been moved off the
# picture's left edge the first block of a row starts where the picture does.
def rg_block_corner_across(x)
  first = @rg_camera_x < 0 ? -@rg_camera_x : 0
  x >= first ? first + (((x - first) / @rg_read_block) * @rg_read_block) : x
end

# --- a light (Framebuffer#shade_outside) ---

def rg_shade_line = @rg_shade_row

# Where the row's span starts, and then where it ends: two calls, so the game works the left edge
# out before the right one, as the interpreter does.
def rg_shade_left(left)
  @rg_shade_spans[@rg_shade_row][0] = left
end

def rg_shade_right(right)
  @rg_shade_spans[@rg_shade_row][1] = right
end

# FadeSteps.sixteenths: the amount out of 100, in the display's sixteenths.
def rg_shade_darkness(amount)
  @rg_shade_steps = rg_whole_sixteenths(amount)
end

# Reference#work_out_shade: every row's span from the game's own expressions, top to bottom, then
# the amount.
def rg_screen_work_out_shade
  RG_SCREEN_HEIGHT.times do |row|
    @rg_shade_row = row
    rg_game_shade_span
  end
  @rg_shade_row = RG_SCREEN_HEIGHT
  rg_game_shade_amount
end

# Framebuffer#light_off=: whether the scene that just ran has the light switched off, said as the
# frame ends, before it is shown.
def rg_shade_switch(on)
  @rg_shade_off = on == 0
end

# Whether the whole screen is lit: no light darkens anything, or it is switched off.
def rg_all_lit? = @rg_shade_steps == 0 || @rg_shade_off

# Framebuffer#lit?: is (x, y) inside its row's span?
def rg_lit?(x, y)
  return true if rg_all_lit?

  left, right = @rg_shade_spans[y]
  left <= right ? x >= left && x < right : x >= left || x < right
end

# Framebuffer#shown and #pixel: the page a viewer is looking at, read through the window — off the
# edge of the picture the backdrop shows — with the fade or tint in force mixed in, in blocks when a
# painted screen is shown in them, and darkened outside a light's span. A switched-off display
# shows plain white.
#
# With nothing over the picture — no tint, no fade, no light, not in blocks — every row is the
# stored row moved by the window, and is copied as one, which is most frames of most games.
def rg_screen_shown
  rg_screen_paint_owed_rebuild
  shown = @rg_shown
  viewed = @rg_viewed
  held = @rg_screen_held != 0
  return shown.fill(RG_SWITCHED_OFF) if held
  if @rg_tint_mode == :none && @rg_fade_steps == 0 && @rg_read_block == 1 && rg_all_lit?
    return rg_screen_shown_plain(shown, viewed)
  end

  # A fade or a tint does the same to every cell of one color, so each color's answer is worked out
  # once a picture (two answers: where the fade reaches and where it does not). A cell a
  # see-through layer was mixed into, under a tint, is mixed again from its own two colors, and is
  # worked out for itself (rg_shown_color).
  faded_in = Array.new(0x10000) # a cell holds sixteen bits
  faded_out = {}
  remixed = @rg_tint_mode != :none && @rg_pixels.equal?(@rg_viewed)
  mixed_cells = @rg_picture_mixes.is_mixed
  block = @rg_read_block
  camera_x = @rg_camera_x
  whole_fade = @rg_fade_side == RG_FADE_WHOLE_SCREEN
  all_lit = rg_all_lit?
  RG_SCREEN_HEIGHT.times do |y|
    from_y = y - (y % block) + @rg_camera_y
    row = y * RG_SCREEN_WIDTH
    x = 0
    while x < RG_SCREEN_WIDTH
      from_x = (block == 1 ? x : rg_block_corner_across(x)) + camera_x
      fade_here = whole_fade || rg_fade_reaches?(x, y)
      color = if from_x >= 0 && from_x < RG_SCREEN_WIDTH && from_y >= 0 && from_y < RG_SCREEN_HEIGHT
                at = (from_y * RG_SCREEN_WIDTH) + from_x
                stored = viewed[at]
                if remixed && mixed_cells[at] != 0
                  rg_shown_color(at, stored, fade_here)
                else
                  answers = fade_here ? faded_in : faded_out
                  answers[stored] ||= rg_faded_where(stored, fade_here)
                end
              else
                rg_faded_where(0, fade_here)
              end
      shown[row + x] = all_lit || rg_lit?(x, y) ? color : rg_darkened_by_display(color, @rg_shade_steps)
      x += 1
    end
  end
  shown
end

# rg_screen_shown with nothing over the picture: each row the stored row the window sits over, and
# off the picture the backdrop, which is nought (rg_faded_where with nothing in force). In blocks of
# one, the column a pixel shows is its own (rg_block_corner_across).
def rg_screen_shown_plain(shown, viewed)
  camera_x = @rg_camera_x
  camera_y = @rg_camera_y
  RG_SCREEN_HEIGHT.times do |y|
    row = y * RG_SCREEN_WIDTH
    from_y = y + camera_y
    if from_y < 0 || from_y >= RG_SCREEN_HEIGHT
      shown.fill(0, row, RG_SCREEN_WIDTH)
    elsif camera_x == 0
      shown[row, RG_SCREEN_WIDTH] = viewed[from_y * RG_SCREEN_WIDTH, RG_SCREEN_WIDTH]
    else
      from_row = from_y * RG_SCREEN_WIDTH
      x = 0
      while x < RG_SCREEN_WIDTH
        from_x = x + camera_x
        shown[row + x] = from_x >= 0 && from_x < RG_SCREEN_WIDTH ? viewed[from_row + from_x] : 0
        x += 1
      end
    end
  end
  shown
end

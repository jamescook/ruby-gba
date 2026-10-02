# frozen_string_literal: true

require "test_helper"

# The reference backend's simulated hardware: run hand-built IR programs that draw and
# read input, then assert what landed on the fake screen and which branch a
# supplied button state took. Still no emulator and no ROM — the point is that a
# game's *visible* behavior is assertable in-process.
class TestIRBackendReferenceHardware < Minitest::Test
  include RubyGBA::IR::Build

  def run_ir(node, **opts)
    Reference.new.run(node, **opts)
  end

  # ---- drawing into the framebuffer ----

  def test_clear_screen_paints_the_whole_screen
    i = run_ir(program(screen(:bitmap), clear_screen(:blue)))
    assert_equal Color.resolve(:blue), i.screen.pixel(0, 0)
    assert_equal Color.resolve(:blue), i.screen.pixel(239, 159)
  end

  # A tear-free screen is two pages: the program draws into one while the display
  # shows the other, and they trade places at the frame boundary. So drawing alone
  # puts nothing on screen — the drawing is sitting on the page nobody is looking
  # at. That is the console's own behavior, measured, not a quirk of this oracle.
  def test_drawing_on_a_tear_free_screen_shows_nothing_until_the_frame_ends
    i = run_ir(program(screen(:bitmap, buffered: true), clear_screen(:blue)))
    assert i.buffered
    assert_equal 0, i.screen.pixel(120, 80)
  end

  # ...and the frame boundary is what presents it.
  def test_the_frame_boundary_presents_the_page_just_drawn
    i = run_ir(program(screen(:bitmap, buffered: true), clear_screen(:blue), wait_vblank))
    assert_equal Color.resolve(:blue), i.screen.pixel(120, 80)
  end

  def test_pixel_writes_a_resolved_color_at_coordinates
    i = run_ir(program(pixel(10, 20, :red)))
    assert_equal Color.resolve(:red), i.screen.pixel(10, 20)
    assert_equal 0, i.screen.pixel(11, 20) # neighbor untouched
  end

  def test_pixel_coordinates_can_come_from_variables
    i = run_ir(program(
      set(:px, 100),
      set(:py, 50),
      pixel(:px, :py, :green),
    ))
    assert_equal Color.resolve(:green), i.screen.pixel(100, 50)
  end

  def test_fill_rect_paints_a_block
    i = run_ir(program(fill_rect(5, 5, 3, 2, :yellow)))
    assert_equal Color.resolve(:yellow), i.screen.pixel(5, 5)
    assert_equal Color.resolve(:yellow), i.screen.pixel(7, 6) # bottom-right
    assert_equal 0, i.screen.pixel(8, 5)                      # just outside
  end

  def test_dma_fill_rect_paints_a_block
    # Same picture as fill_rect — the "DMA" is only how a console fills it fast.
    i = run_ir(program(dma_fill_rect(4, 6, 4, 2, :red)))
    assert_equal Color.resolve(:red), i.screen.pixel(4, 6)
    assert_equal Color.resolve(:red), i.screen.pixel(7, 7) # bottom-right (4+4-1, 6+2-1)
    assert_equal 0, i.screen.pixel(8, 6)                    # just outside
  end

  def test_draw_rect_at_positions_the_block_from_variables
    # The moving-object draw: its position comes from variables at run time.
    i = run_ir(program(
      set(:x, 30),
      set(:y, 40),
      draw_rect_at(:x, :y, 4, 4, :green),
    ))
    assert_equal Color.resolve(:green), i.screen.pixel(30, 40)
    assert_equal Color.resolve(:green), i.screen.pixel(33, 43) # bottom-right corner
    assert_equal 0, i.screen.pixel(34, 40)                     # just outside
  end

  def test_draw_text_renders_glyph_pixels
    # 'I' in the 5x7 font has a set pixel at its top-left corner (row 0 = 0x0E,
    # so columns 1..3 are lit) — assert a lit and an unlit cell of the glyph.
    i = run_ir(program(draw_text("I", 10, 20, :white)))
    assert_equal Color.resolve(:white), i.screen.pixel(11, 20) # a lit pixel of 'I'
    assert_equal 0, i.screen.pixel(10, 20)                      # an unlit corner
  end

  def test_draw_text_skips_unsupported_characters
    # The font has no '@'; drawing it must not raise, just render nothing.
    i = run_ir(program(draw_text("@", 0, 0, :white)))
    assert_equal 0, i.screen.pixel(0, 0)
  end

  def test_off_screen_pixel_is_clipped_without_error
    # The safe-by-default promise: a stray coordinate can't crash a program.
    i = run_ir(program(pixel(999, 999, :red)))
    assert_equal 0, i.screen.pixel(0, 0)
  end

  def test_screen_mode_is_recorded
    i = run_ir(program(screen(:bitmap)))
    assert_equal :bitmap, i.screen_mode
  end

  # ---- reading input ----

  def test_held_button_takes_the_branch
    i = Reference.new.hold(:a).run(program(
      if_(held(:a), set(:jumped, 1)),
      if_(held(:b), set(:shot, 1)),
    ))
    assert_equal 1, i[:jumped]
    assert_equal 0, i[:shot]
  end

  def test_unheld_button_skips_the_branch
    i = Reference.new.run(program(if_(held(:up), set(:moved, 1))))
    assert_equal 0, i[:moved]
  end

  def test_pressed_is_an_edge_only_the_first_frame_a_button_is_down
    # Button :a is held on every frame, but "pressed" should fire once — the
    # frame the button first goes down, not while it stays down.
    i = Reference.new.input_each_frame { |_frame| [:a] }.run(program(
      set(:count, 0),
      set(:presses, 0),
      loop_(
        wait_vblank,
        if_(pressed(:a), add(:presses, 1)),
        add(:count, 1),
        if_(binop(:>=, var_ref(:count), int(3)), halt),
      ),
    ))
    assert_equal 3, i[:count]
    assert_equal 1, i[:presses]
  end

  def test_unknown_button_is_a_friendly_error
    err = assert_raises(Reference::ProgramError) do
      Reference.new.run(program(if_(held(:triangle), set(:x, 1))))
    end
    assert_match(/triangle/, err.message)
  end

  # ---- audio (an observable record of what would play) ----

  def test_sound_ops_are_recorded_in_the_audio_log
    i = run_ir(program(enable_sound, beep(:high)))
    assert_equal [:enabled], i.audio[0]
    assert_equal :beep, i.audio[1][0]
    assert_equal 880, i.audio[1][1].frequency # :high resolves to 880 Hz
  end

  def test_a_noise_hit_is_recorded_with_its_resolved_values
    i = run_ir(program(enable_sound, noise(:explosion)))
    assert_equal :noise, i.audio[1][0]
    assert_equal({ pitch: :low, decay: :slow, volume: 15, metallic: false }, i.audio[1][1])
  end

  def test_a_wave_tone_and_its_stop_are_recorded
    i = run_ir(program(enable_sound, wave(shape: :triangle, frequency: 262, volume: :full), stop_wave))
    assert_equal [:wave, { shape: :triangle, frequency: 262, volume: :full }], i.audio[1]
    assert_equal [:stop_wave], i.audio[2]
  end

  def test_beep_resolves_a_defined_sound_by_name
    i = run_ir(program(
      enable_sound,
      define_sound(:paddle, frequency: 500, duty: :quarter, decay: :fast, volume: 12),
      beep(:paddle),
    ))
    effect = i.audio.find { |e| e[0] == :beep }[1]
    assert_equal 500, effect.frequency
    assert_equal :quarter, effect.duty
  end

  def test_a_beep_override_wins_over_the_preset
    i = run_ir(program(enable_sound, beep(:high, volume: 3)))
    assert_equal 3, i.audio.find { |e| e[0] == :beep }[1].volume
  end

  def test_play_song_triggers_notes_frame_by_frame_and_loops
    i = run_ir(program(
      enable_sound,
      song(:tune, events: [[0, 262], [2, 330]], total_frames: 4),
      set(:n, 0),
      loop_(
        wait_vblank,
        play_song(:tune),
        add(:n, 1),
        if_(binop(:>=, var_ref(:n), int(6)), halt),
      ),
    ))
    notes = i.audio.select { |e| e[0] == :note }
    # The counter runs 0,1,2,3,0,1: frame 0 fires 262 (the downbeat), frame 2 fires
    # 330, then it wraps at length 4 and frame 0 fires 262 again — the loop.
    assert_equal [[:note, :tune, 262], [:note, :tune, 330], [:note, :tune, 262]], notes
  end

  # A layered song's parts play against one shared frame counter, so notes on the
  # same frame in different parts sound together. Four passes: the tune is named on the
  # first, and the player takes it up at the frame after, so the fourth reaches its frame 2.
  def test_play_song_plays_layered_parts_together
    i = run_ir(program(
      enable_sound,
      song(:duet, total_frames: 4, voices: [
        RubyGBA::Audio::Music::Part.new(events: [[0, 523], [2, 587]]),        # melody: C5 then D5
        RubyGBA::Audio::Music::Part.new(events: [[0, 131]], volume: 8),       # bass: C3, held
      ]),
      set(:n, 0),
      loop_(
        wait_vblank,
        play_song(:duet),
        add(:n, 1),
        if_(binop(:>=, var_ref(:n), int(4)), halt),
      ),
    ))
    notes = i.audio.select { |e| e[0] == :note }
    # Frame 0: melody C5 (523) and bass C3 (131) together; frame 2: melody D5 (587).
    assert_includes notes, [:note, :duet, 523]
    assert_includes notes, [:note, :duet, 131]
    assert_includes notes, [:note, :duet, 587]
  end

  # ---- observation log ----

  def test_log_records_vblank_ticks_and_halt
    i = run_ir(program(
      set(:x, 0),
      loop_(
        wait_vblank,
        add(:x, 1),
        if_(binop(:>=, var_ref(:x), int(2)), halt),
      ),
    ))
    assert_equal [[:vblank, 1], [:vblank, 2], [:halt]], i.log
  end

  # ---- a repaint is owed until something looks ----
  #
  # Repainting a scrolled view is most of what a frame costs here, and a test that reads only
  # variables never looks at it, so the repaint waits until something does. What that must never
  # change is the picture: read at the end of a run, it is the one a watcher reading every frame
  # saw at that moment. A scene that scrolls, changes a tile, changes its colours and moves a
  # sprite, so every kind of repaint is owed and settled somewhere in it.
  def a_scene_that_changes_every_way
    tile = (["#" * 8] * 8).join("\n")
    builder = RubyGBA::Builder.new
    builder.instance_eval do
      screen :tiled
      colors :day, %i[transparent red]
      colors :dusk, %i[transparent blue]
      image(:brick, "#" => :red, colors: :day) { tile }
      image(:ghost, "#" => :white) { tile }
      tiles :set, "#" => :brick, "." => :brick
      field = background :field, tiles: :set, map: Array.new(20) { |r| (r.even? ? "#." : ".#") * 15 }
      ghost = sprite :ghost, at: [10, 10]
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        field.scroll_by 3, 1
        ghost.move 2, 1
        (tick == 3).then { field.set_tile 1, 1, "#" }
        (tick == 5).then { field.draw_with :dusk }
      end
    end
    builder.finalize_program
    builder.program
  end

  # Every frame's picture as a watcher reading it each frame saw it, and the picture read at
  # the end of a run of each length up to +frames+ - 1, which must be the watched one.
  def assert_each_ending_is_the_one_watched(program, frames:)
    watched = {}
    watcher = Reference.new
    watcher.each_vblank { |call| watched[call] = watcher.screen.shown }
    watcher.run(program, frames: frames)
    (1...frames - 1).each do |ran|
      ended = Reference.new.run(program, frames: ran).screen.shown
      # A run of N frames stops at the boundary the watcher is called at for the N+1th time.
      assert ended == watched.fetch(ran + 1), "the picture read after #{ran} frames is not the one watched"
    end
    watched
  end

  def test_a_picture_read_after_a_run_is_the_one_watched_at_that_moment
    watched = assert_each_ending_is_the_one_watched(a_scene_that_changes_every_way, frames: 10)

    # ...and the pictures are really painted, not merely equally stale: the view scrolls every
    # frame, and the colour change arrives.
    assert_equal watched.size, watched.values.uniq.size, "a frame showed the same picture as another"
    assert_includes watched.fetch(10), Color.resolve(:blue), "the layer never drew with its other colours"
  end

  # A picture whose painting reads variables — a background bent row by row, or a see-through
  # amount the game works out — is a fact about the screen showing it, not about the game:
  # here a title bends its backdrop and works out how see-through its rays are, hands over to
  # a plain screen that scrolls, and (unless told otherwise) comes back.
  def title_and_plain_screen(bends: true, comes_back: true)
    tile = (["#" * 8] * 8).join("\n")
    builder = RubyGBA::Builder.new
    builder.instance_eval do
      screen :tiled
      layers :back, :rays
      image(:brick, "#" => :red) { tile }
      image(:light, "#" => :yellow) { tile }
      tiles :set, "#" => :brick, "." => :brick
      tiles :glow, "#" => :light
      grid = Array.new(20) { |r| (r.even? ? "#." : ".#") * 15 }
      tick = var :tick, 0
      state = var :state, 0
      scene :title do
        layer(:back) do
          sky = background :sky, tiles: :set, map: grid
          sky.scroll_each_row { |row| (row + tick) % 5 } if bends
        end
        layer(:rays, transparency: 40 + (tick % 4)) { background :rays, tiles: :glow, map: ["#" * 30] * 4 }
      end
      scene :plain do
        field = layer(:back) { background :field, tiles: :set, map: grid }
        field.scroll_by 3, 1
      end
      game_loop do
        tick.add! 1
        if comes_back
          state.set!((tick / 4) % 2)
        else
          (tick == 4).then { state.set! 1 }
        end
        case_var(:state) do
          when_val 0, :title
          when_val 1, :plain
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_painting_later_shows_what_painting_at_once_showed_across_screens_that_bend_and_do_not
    assert_each_ending_is_the_one_watched(title_and_plain_screen, frames: 12)
    assert_each_ending_is_the_one_watched(title_and_plain_screen(bends: false), frames: 12)
  end

  # Counts each time the interpreter paints the whole picture, for the tests below. Painting is
  # the one thing they are about, and nothing a game does shows it — the picture comes out the
  # same either way — so it is counted where it happens.
  COUNTS_PAINTS = Module.new do
    def repaint_view
      @paints = @paints.to_i + 1
      super
    end

    def paints = @paints.to_i
  end

  # How many whole pictures a run of +program+ had painted by each frame, with nothing
  # reading the picture.
  def paints_by_frame(program, frames:)
    run = Reference.new
    run.singleton_class.prepend(COUNTS_PAINTS)
    paints = []
    run.each_vblank { |_| paints << run.paints }
    run.run(program, frames: frames)
    paints
  end

  # What waiting is for: a plain screen paints nothing while nobody looks, whatever another
  # screen in the game does. Painting every frame — what a title that bends used to cost the
  # whole game — is a paint or more on every frame of it.
  def test_a_plain_screen_does_not_paint_while_nobody_looks_beside_a_screen_that_bends
    paints = paints_by_frame(title_and_plain_screen(comes_back: false), frames: 40)

    on_the_plain_screen = paints.last - paints[10] # it takes over on the fourth
    assert_equal 0, on_the_plain_screen, "the plain screen painted while nobody looked"
    assert_operator paints[3], :>=, 3, "the title that bends paints every frame"
  end

  # A screen with a strip of scenery in front of a field, the field scrolling every frame unless
  # told not to, a background that turns and changes size every frame if asked for, and whatever
  # +each_frame+ adds to the game loop (handed the frame count).
  def a_screen(see_through: false, scrolls: true, turns: false, &each_frame)
    tile = (["#." * 4, ".#" * 4] * 4).join("\n")
    builder = RubyGBA::Builder.new
    builder.instance_eval do
      screen :tiled
      layers :back, :front
      image(:brick, "#" => :red, "." => :blue) { tile }
      tiles :set, "#" => :brick
      grid = Array.new(20) { |r| (r.even? ? "# " : " #") * 15 }
      tick = var :tick, 0
      field = layer(:back) { background :field, tiles: :set, map: grid }
      sword = layer(:back) { background :sword, tiles: :set, map: Array.new(16) { |r| (r < 8 ? "#" : " ") * 16 } } if turns
      layer(:front, **(see_through ? { transparency: 40 } : {})) { background :strip, tiles: :set, map: ["#" * 30] * 3 }
      game_loop do
        tick.add! 1
        field.scroll_by 3, 1 if scrolls
        if turns
          sword.rotate tick * 7
          sword.scale 1.0 + (tick % 8).to_f / 8
        end
        instance_exec(tick, &each_frame) if each_frame
      end
    end
    builder.finalize_program
    builder.program
  end

  # Nothing painted from the fourth frame on, while nobody read the picture, and each picture
  # read at the end of a run is the one a watcher saw.
  def assert_effect_paints_only_when_looked_at(program, frames: 30)
    paints = paints_by_frame(program, frames: frames)
    assert_equal 0, paints.last - paints[3], "the effect painted while nobody looked"
    assert_each_ending_is_the_one_watched(program, frames: frames)
  end

  def test_a_fade_over_the_whole_screen_paints_nothing_while_nobody_looks
    %i[white black].each do |color|
      assert_effect_paints_only_when_looked_at(a_screen do |tick|
        (tick == 4).then { fade_out color, frames: 8 }
        (tick == 16).then { fade_in }
      end)
    end
  end

  # Longer than the display's own seventeen steps, so the colors are walked instead.
  def test_a_walked_fade_paints_nothing_while_nobody_looks
    assert_effect_paints_only_when_looked_at(a_screen do |tick|
      (tick == 4).then { fade_out :black, frames: 24 }
      (tick == 30).then { fade_in }
    end, frames: 60)
  end

  def test_a_tinted_flash_paints_nothing_while_nobody_looks
    assert_effect_paints_only_when_looked_at(a_screen do |tick|
      ((tick % 10) == 4).then { flash_screen :red }
    end)
  end

  # A placed fade is painted into the picture, so it is the one fade that repaints — on the
  # frame it is told, which is the one that has to show it, never on a frame nobody reads.
  def test_a_placed_fade_paints_nothing_while_nobody_looks
    [false, true].each do |see_through|
      assert_effect_paints_only_when_looked_at(a_screen(see_through: see_through) do |tick|
        (tick == 4).then { fade_out frames: 8, under: :front }
        (tick == 16).then { fade_in }
      end)
    end
  end

  def test_a_background_that_turns_paints_nothing_while_nobody_looks
    assert_effect_paints_only_when_looked_at(a_screen(turns: true), frames: 20)
  end

  # A placed fade is painted into the picture and a fade over the whole screen is not, so the
  # one taking the other's place has to paint the placed one out — even on a still screen
  # somebody is watching, where nothing else would.
  def test_a_whole_screen_fade_taking_a_placed_ones_place_leaves_none_of_it_in_the_picture
    placed_then_lifted = a_screen(scrolls: false) do |tick|
      (tick == 4).then { fade :black, 50, under: :front }
      (tick == 8).then { fade :black, 0 }
    end
    never_faded = Reference.new.run(a_screen(scrolls: false), frames: 12).screen.shown
    watcher = Reference.new
    watcher.each_vblank { |_| watcher.screen.shown }
    assert watcher.run(placed_then_lifted, frames: 12).screen.shown == never_faded,
           "the placed fade was still in the picture after a whole-screen fade took its place"
  end
end

# frozen_string_literal: true

require_relative "test_helper"

# WHAT HAPPENED WHILE THAT FRAME RAN.
#
# The binding's contract has been "run a frame, then ask questions", so everything about
# WHEN something happened had to be reconstructed afterwards — and some of it could not be
# reconstructed at all, so the framework resorted to adding a counter to the cartridge and
# measuring that instead. The core tells us these things itself; it just has to be asked.
class TestFrameEvents < Minitest::Test
  include RubyGBAEmulatorTestSupport

  # A tiled screen draws from 8x8 tiles, so that is what a tileset's art has to be.
  TILE_8X8 = ("########\n" * 8).freeze

  def test_a_probe_says_how_often_the_game_asked_for_buttons
    path = build_rom("PADREAD", code: "TPAD") do
      screen :bitmap
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        held(:right).then { tick.add! 1 }
      end
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(8)

    assert_operator probe.pad_reads, :>, 0, "the game ran, and it reads the pad every pass"
    assert_operator probe.pad_reads, :<=, 8, "it cannot have asked more often than there were frames"
  end

  # The trap this name exists to avoid: a game loop that never asks for input reads the pad
  # never, however many times it goes round. So this counts the asking, and a test wanting
  # passes has to count something else.
  def test_a_game_that_never_asks_for_buttons_reads_the_pad_never
    path = build_rom("NOPAD", code: "TNOP") do
      screen :bitmap
      game_loop { clear_screen :blue }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(8)

    assert_equal 0, probe.pad_reads
  end

  # WHERE THE SPRITES ARE, asked rather than deduced.
  #
  # A test that wants to know where a sprite is has had to hunt for its pixels and reason
  # backwards — which fails for a sprite behind something, one drawn in the backdrop colour,
  # or one off the edge, and says nothing at all about a sprite that is hidden when it
  # should not be. The console keeps a table of them and the emulator has it.
  def test_a_probe_can_read_the_sprites_the_console_is_showing
    path = build_rom("SPRITES", code: "TSPR") do
      screen :tiled
      image(:dot, "." => :transparent, "#" => :red) { <<~ART }
        ########
        ########
        ########
        ########
        ########
        ########
        ########
        ########
      ART
      sprite :dot, at: [40, 24]
      game_loop { wait_vblank }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(4)
    shown = probe.sprites

    assert_equal 1, shown.size, "one sprite was declared, so one is on screen"
    assert_equal 40, shown.first[:x]
    assert_equal 24, shown.first[:y]
  end

  # A sprite the game has hidden is not on screen, and the table says so rather than the
  # test inferring it from an absence of pixels — which is the same picture a sprite drawn
  # in the backdrop colour makes.
  def test_a_hidden_sprite_is_not_among_the_ones_being_shown
    path = build_rom("HIDDEN", code: "THID") do
      screen :tiled
      image(:dot, "." => :transparent, "#" => :red) { <<~ART }
        ########
        ########
        ########
        ########
        ########
        ########
        ########
        ########
      ART
      s = sprite :dot, at: [40, 24]
      s.hide
      game_loop { wait_vblank }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(4)

    assert_empty probe.sprites
  end

  # THE COLOURS THE CONSOLE IS DRAWING FROM. A game fades, tints, or swaps a character's
  # colours by changing this table rather than by redrawing anything — so "did the fade
  # happen" read off the picture is really a question about these numbers, asked the long
  # way round and confounded by whatever else is on screen.
  def test_a_probe_can_read_the_colours_the_console_is_drawing_from
    path = build_rom("PALETTE", code: "TPAL") do
      screen :tiled
      image(:brick, "#" => :red) { TILE_8X8 }
      tiles :set, "#" => :brick
      background :bg, tiles: :set, map: "##\n##\n"
      game_loop { wait_vblank }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(4)
    colours = probe.palette

    assert_equal 512, colours.size, "the console holds 512 colours, backgrounds then sprites"
    assert(colours.any? { |c| c.positive? }, "the game declared colours, so some are set")
  end

  # WHERE THE CAMERA IS. A scrolling game moves the window over its map, and the registers
  # that say by how much are write-only on the hardware — so a test reading the picture can
  # only guess at it. The emulator kept the values.
  def test_a_probe_can_read_where_each_background_is_scrolled_to
    path = build_rom("SCROLL", code: "TSCR") do
      screen :tiled
      image(:brick, "#" => :red) { TILE_8X8 }
      tiles :set, "#" => :brick
      bg = background :bg, tiles: :set, map: "##\n##\n"
      game_loop { bg.scroll_to 24, 8 }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(6)
    across, down = probe.scroll(0)

    assert_equal 24, across
    assert_equal 8, down
  end

  # BEING TOLD WHEN A VARIABLE CHANGED, rather than looking at it once a frame and inferring
  # the rest. Sampling cannot see a value that moved twice between looks, cannot say WHEN
  # inside the frame it moved, and cannot say what it moved from. For a port chasing "what
  # is knocking the player's health down", those are the whole question.
  def test_a_probe_reports_every_change_to_a_watched_address
    rom = RubyGBA.build("WATCH", validate: false) do
      screen :bitmap
      hp = var :hp, 100
      game_loop { hp.sub! 7 }
    end
    address = rom.var_addresses.fetch(:hp)
    path = write_rom(rom, "watch")

    probe = RubyGBAEmulator.open(path)
    probe.watch(address)
    probe.step(4)
    changes = probe.changes

    # Every write is reported, the boot one included: the variable is given its starting
    # value, and then each pass takes seven off.
    assert_equal [[0, 100], [100, 93], [93, 86], [86, 79]],
                 changes.map { |c| [c.was, c.now] }
    assert(changes.all? { |c| c.address == address })
    assert_equal 0, probe.changes_missed, "four changes is nowhere near a frame's worth"
  end

  # The block form: what to do with a change sits next to the asking.
  def test_a_watcher_can_be_handed_a_block_to_run_on_each_change
    rom = RubyGBA.build("WATCHBLK", validate: false) do
      screen :bitmap
      hp = var :hp, 50
      game_loop { hp.sub! 5 }
    end
    path = write_rom(rom, "watchblk")

    seen = []
    probe = RubyGBAEmulator.open(path)
    probe.watch(rom.var_addresses.fetch(:hp)) { |change| seen << [change.was, change.now] }
    probe.step(3)

    assert_equal [[0, 50], [50, 45], [45, 40]], seen
    assert_equal seen.size, probe.changes.size, "the block sees what the record keeps"
  end

  # The record is emptied every frame, so it only has to hold ONE frame's changes — 12,000
  # spread over sixty frames fit easily. What does not fit is one frame that moves an address
  # thousands of times, and a truncated list that does not say so reads like the whole story.
  def test_a_single_frame_that_moves_an_address_too_often_says_what_was_missed
    rom = RubyGBA.build("BUSY", validate: false) do
      screen :bitmap
      hp = var :hp, 0
      game_loop { repeat(6000) { hp.add! 1 } }
    end
    path = write_rom(rom, "busywatch")

    probe = RubyGBAEmulator.open(path)
    probe.watch(rom.var_addresses.fetch(:hp))
    probe.step(2)

    assert_operator probe.changes_missed, :>, 0, "6,000 changes in one frame do not fit"
  end

  # Watching costs something, so a probe nobody asked to watch anything pays nothing and
  # reports nothing.
  def test_a_probe_asked_to_watch_nothing_reports_nothing
    path = build_rom("NOWATCH", code: "TNOW") do
      screen :bitmap
      game_loop { clear_screen :blue }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(4)

    assert_empty probe.changes
  end

  # What the emulator itself said while the frame ran. mGBA reports a bad read or an
  # unimplemented register as a log line; the binding has been discarding every one of them,
  # so a cartridge doing something the console would object to fails a test silently.
  def test_a_probe_keeps_what_the_emulator_said
    path = build_rom("QUIET", code: "TQUI") do
      screen :bitmap
      game_loop { clear_screen :blue }
    end

    probe = RubyGBAEmulator.open(path)
    probe.step(4)

    assert probe.respond_to?(:complaints), "a probe can say what the emulator complained about"
    assert_kind_of Array, probe.complaints
  end

  # TAKING THE PICTURE APART. The console composes one picture out of four backgrounds and
  # the sprites, and the finished picture cannot be asked which of them drew a given pixel —
  # so "is the HUD drawing at all" has no answer in it. A HUD sitting behind the scenery, or
  # drawn in the colour already there, makes exactly the same picture as one that never drew.
  # The emulator can leave a layer out, and then the question is just "what changed".

  RED = [255, 0, 0].freeze
  BLUE = [0, 0, 255].freeze

  # A background over the whole screen with one blue sprite sitting on it.
  def layered_rom
    build_rom("LAYERS", code: "TLAY") do
      screen :tiled
      image(:brick, "#" => :red) { TILE_8X8 }
      image(:dot, "." => :transparent, "#" => :blue) { TILE_8X8 }
      tiles :set, "#" => :brick
      background :ground, tiles: :set, map: ["#" * 30] * 20
      sprite :dot, at: [40, 24]
      game_loop { wait_vblank }
    end
  end

  def test_a_probe_says_which_layers_and_channels_the_console_has
    with_probe(red_rom) do |probe|
      assert_equal %i[bg0 bg1 bg2 bg3 sprites window0 window1 sprite_window], probe.layers
      assert_equal %i[square1 square2 wave noise sample_a sample_b], probe.channels
    end
  end

  def test_a_probe_can_leave_one_layer_out_and_put_it_back
    with_probe(layered_rom) do |probe|
      probe.step(4)

      assert_equal BLUE, probe.pixel(44, 28), "the sprite is drawn over the scenery"

      probe.showing(without: :sprites) do
        probe.step(2)

        assert_equal RED, probe.pixel(44, 28), "with the sprites out, the scenery behind shows"
      end

      probe.step(2)

      assert_equal BLUE, probe.pixel(44, 28), "and the sprite is back once the block has ended"
    end
  end

  def test_a_probe_can_show_one_layer_on_its_own
    with_probe(layered_rom) do |probe|
      probe.step(4)

      assert_equal RED, probe.pixel(100, 100), "scenery everywhere the sprite is not"

      probe.showing(only: :sprites) do
        probe.step(2)

        assert_equal BLUE, probe.pixel(44, 28), "the sprite still draws"
        refute_equal RED, probe.pixel(100, 100), "and nothing else does"
      end
    end
  end

  # A TONE HELD ON ONE VOICE, and which voice it really came out of. A game with music under
  # its effects cannot tell from the loudness alone which of them sounded — silencing the
  # others is the only way to put that question.
  def sustained_tone_rom
    build_rom("TONE", code: "TTON") do
      screen :bitmap
      clear_screen :black
      enable_sound
      wave :triangle, :C4
      game_loop { wait_vblank }
    end
  end

  # Taking a voice out from under a note it is HOLDING is a cut rather than a rest: the mix
  # steps down where the note was and drifts back over about half a second, which is the same
  # click a game gets for stopping a note dead. So the tone goes quiet shortly after, not at
  # the instant — and a test that reads the loudness straight away reads the cut.
  SETTLE_AFTER_A_CUT = 50

  def test_a_probe_can_leave_one_sound_channel_out
    with_probe(sustained_tone_rom) do |probe|
      probe.step(10)

      refute probe.silent?, "the game is holding a tone"

      probe.hearing(without: :wave) do
        probe.step(SETTLE_AFTER_A_CUT)
        probe.step(10)

        assert probe.silent?, "with that voice out, nothing is left sounding (#{probe.audio_energy})"
      end

      probe.step(10)

      refute probe.silent?, "the voice comes back once the block has ended"
    end
  end

  # Said before a frame has run, so nothing is cut and there is nothing to settle: the tone
  # sounds on the voice the game named and on no other.
  def test_a_probe_can_hear_one_sound_channel_on_its_own
    with_probe(sustained_tone_rom) do |probe|
      probe.hearing(only: :wave) { probe.step(10) }

      refute probe.silent?, "the tone is on the voice the game named"
    end

    with_probe(sustained_tone_rom) do |probe|
      probe.hearing(only: :noise) { probe.step(10) }

      assert probe.silent?, "and on no other (#{probe.audio_energy})"
    end
  end

  # WHAT THE GAME TOLD THE DISPLAY, WRITE BY WRITE, AND ON WHICH ROW.
  #
  # Everything else here reads the console once a frame, which is fine while a game sets the
  # display up between pictures and leaves it alone. A game that changes the display WHILE
  # the picture is being drawn — a background that bends row by row, a split screen, a
  # colour that changes half way down — cannot be seen that way at all: by the time the
  # frame ends the registers hold whatever the last row left in them, and every earlier
  # value is gone. This is the only instrument that can say those happened.
  def test_a_probe_can_be_told_every_write_the_game_makes_to_the_display
    path = build_rom("SCROLLW", code: "TSCW") do
      screen :tiled
      image(:brick, "#" => :red) { TILE_8X8 }
      tiles :set, "#" => :brick
      bg = background :bg, tiles: :set, map: ["#" * 30] * 20
      game_loop { bg.scroll_to 24, 8 }
    end

    with_probe(path) do |probe|
      probe.watch_display
      probe.step(4)
      scrolls = probe.display_writes.select { |w| w.kind == :register && w.value == 24 }

      refute_empty scrolls, "the game set the camera across, and that is a write to the display"
      assert(scrolls.all? { |w| w.row.between?(0, 227) }, "each one says which row was being drawn")
    end
  end

  # THE CASE NOTHING ELSE REACHES: a background bent row by row writes the same register
  # over and over inside one frame, and only the last of those values is still there to read
  # when the frame ends.
  def test_a_write_made_part_way_down_the_picture_is_seen_where_it_happened
    path = build_rom("BENDW", code: "TBND") do
      screen :tiled
      image(:brick, "#" => :red) { TILE_8X8 }
      tiles :set, "#" => :brick
      bg = background :bg, tiles: :set, map: ["#" * 30] * 20
      bg.scroll_each_row { |row| row }
      game_loop { wait_vblank }
    end

    with_probe(path) do |probe|
      probe.watch_display
      probe.step(4)
      rows = probe.display_writes.select { |w| w.kind == :register }.map(&:row).uniq

      assert_operator rows.size, :>, 100,
                      "a bend writes the camera on row after row, not once for the frame"
    end
  end

  # Each of the console's three taps counts its addresses its own way — two of them from the
  # start of their own memory, one of them in pairs of bytes — so a write says the address it
  # really landed at, and reading that address back gives what the write put there.
  def test_a_write_says_the_address_it_landed_at
    path = build_rom("WHEREW", code: "TWHR") do
      screen :tiled
      image(:brick, "#" => :red) { TILE_8X8 }
      image(:dot, "." => :transparent, "#" => :blue) { TILE_8X8 }
      tiles :set, "#" => :brick
      background :bg, tiles: :set, map: ["#" * 30] * 20
      sprite :dot, at: [40, 24]
      game_loop { wait_vblank }
    end

    with_probe(path) do |probe|
      probe.watch_display
      probe.step(6)
      settled = probe.display_writes.group_by(&:address).transform_values(&:last)
      colour = settled.values.find { |w| w.kind == :colour }
      sprite = settled.values.find { |w| w.kind == :sprite }

      assert colour, "the game declared colours, so it wrote some"
      assert_equal colour.value, probe.read16(colour.address),
                   "the colour is at the address the write named"
      assert_equal sprite.value, probe.read16(sprite.address),
                   "and so is the sprite's own entry"
    end
  end

  # Recording the writes puts a shim in front of the console's renderer, and leaving a layer
  # out is set ON that renderer — so the two touch the same thing and the one is easy to
  # break with the other.
  def test_a_layer_can_still_be_left_out_while_the_writes_are_recorded
    with_probe(layered_rom) do |probe|
      probe.watch_display
      probe.step(4)

      assert_equal BLUE, probe.pixel(44, 28), "the sprite is drawn over the scenery"

      probe.showing(without: :sprites) do
        probe.step(2)

        assert_equal RED, probe.pixel(44, 28), "and still goes when the sprites are left out"
      end
      refute_empty probe.display_writes, "the writes were recorded the whole time"
    end
  end

  def test_a_probe_nobody_asked_records_no_writes
    with_probe(red_rom) do |probe|
      probe.step(4)

      assert_empty probe.display_writes
    end
  end

  def test_asking_for_a_layer_that_does_not_exist_says_which_there_are
    with_probe(red_rom) do |probe|
      error = assert_raises(ArgumentError) { probe.showing(only: :hud) }

      assert_match(/hud/, error.message)
      assert_match(/bg0/, error.message, "the message names the layers there are")
    end
  end

  def test_showing_must_say_whether_it_is_keeping_or_leaving_out
    with_probe(red_rom) do |probe|
      assert_raises(ArgumentError) { probe.showing }
      assert_raises(ArgumentError) { probe.showing(only: :bg0, without: :sprites) }
    end
  end
end

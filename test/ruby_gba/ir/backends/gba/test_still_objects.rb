# frozen_string_literal: true

require "test_helper"
require "differential"

# WHAT A SPRITE THAT NEVER MOVES COSTS THE FRAME, which is a fact about the emitted code
# rather than about the picture — so it is asserted here, and that the picture comes out the
# same either way is asserted here too, on both backends.
#
# The thing that must stay true: a screen that is mostly a still picture costs the frame
# nothing for being still. It used to cost what a screen of things that move costs, because
# the console's table was written from scratch every frame whether or not a single number in
# it had changed — some forty instructions per object, in the body the framework keeps in the
# console's quick memory. A title screen's lettering is a dozen of those objects and more, so
# it took its share of that memory from a routine that really does run every frame.
class TestStillObjects < Minitest::Test
  include Differential
  include RubyGBA::Console::Hardware

  YELLOW = RubyGBA::Graphics::Color.rgb(31, 31, 0)
  RED = RubyGBA::Graphics::Color.rgb(31, 0, 0)

  FRAME = RubyGBA::Cartridge::BuildRecord::FRAME_ROUTINE

  private def built(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  # How much code the frame's own body came to — the number this whole change is about.
  private def frame_bytes(program)
    assemble_rom(program, name: "STILL").built.placement.sizes[FRAME].to_i
  end

  # A title screen of lettering that is shown and then never touched again, handing over to a
  # scene with one sprite the game moves — so the frame always has real work in it and the
  # baseline is a game rather than an empty loop.
  private def title_screen(letters:, moving: false)
    built do
      screen :tiled
      letters.times do |i|
        image :"letter#{i}", width: 16, height: 16, data: Array.new(256, YELLOW)
      end
      image :hero, width: 16, height: 16, data: Array.new(256, RED)
      var :state, 0
      scene :title do
        made = Array.new(letters) { |i| sprite(:"letter#{i}", at: [(i * 16) + 8, 40]) }
        made.first.move(:right, by: 1) if moving && made.any?
        pressed(:start).then { set! :state, 1 }
      end
      scene(:playing) { sprite(:hero, at: [100, 100]).move(:right, by: 1) }
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end
  end

  # THE ONE THAT MATTERS. One still sprite and thirteen of them are the same frame: nothing
  # about them changes once they are on screen, so the frame writes none of them.
  def test_what_still_sprites_cost_the_frame_does_not_depend_on_how_many
    one = frame_bytes(title_screen(letters: 1))
    many = frame_bytes(title_screen(letters: 13))

    assert_equal one, many,
                 "thirteen sprites that never move must cost the frame what one does"
  end

  # ...and a sprite the game DOES move is written every frame, as it must be. Without this
  # the test above passes by never writing anything at all.
  def test_a_sprite_the_game_moves_is_written_every_frame
    still = frame_bytes(title_screen(letters: 4))
    moving = frame_bytes(title_screen(letters: 4, moving: true))

    assert_operator moving, :>, still + 100,
                    "moving one of the four must put its whole write back in the frame"
  end

  # Written once and left there is only right if it is really still there, frame after frame
  # — so the whole picture is compared against the oracle, which draws every sprite every
  # frame and knows nothing about any of this.
  def test_the_lettering_stays_on_screen_frame_after_frame
    (1..6).each { |f| assert_backends_agree(title_screen(letters: 13), frames: f) }
  end

  # And it goes when the scene it belongs to does, which is the one thing a table written
  # once could get wrong: the entries have to be written again on the frame the scene
  # changes, and nobody would notice they were not until a title screen stayed up over the
  # game.
  def test_the_lettering_goes_when_the_scene_changes
    program = title_screen(letters: 13)
    i = Reference.new.input_each_frame { |f| f == 3 ? [:start] : [] }.run(program, frames: 10)

    assert_empty i.sprites.filter_map(&:name).grep(/letter/),
                 "the title's lettering must be gone once the playing scene has taken over"
  end

  # The same on the console, which is where a stale table entry would actually show.
  def test_the_console_shows_the_lettering_and_then_stops_showing_it
    rom = assemble_rom(title_screen(letters: 13), name: "STILL")
    v = assert_emulator_loads_rom(rom, frames: 4)

    refute_empty v.sprites.select { |row| row.name.to_s.start_with?("letter") },
                 "the lettering must be on screen while the title is up"

    v.step(6, keys: KEY_START)
    v.step(4)

    assert_empty v.sprites.select { |row| row.name.to_s.start_with?("letter") },
                 "and gone once the playing scene has taken over"
  end

  # A GAME WITH NO SCENES AT ALL, where nothing can change what is on screen once it is up —
  # so the table is written on the first frame and never again, and the frame has no variable
  # to watch.
  private def one_screen
    built do
      screen :tiled
      image :sign, width: 16, height: 16, data: Array.new(256, YELLOW)
      image :hero, width: 16, height: 16, data: Array.new(256, RED)
      sprite :sign, at: [40, 40]
      moved = sprite(:hero, at: [100, 100])
      game_loop { moved.move(:right, by: 1) }
    end
  end

  def test_a_game_with_no_scenes_keeps_its_still_sprite_on_screen
    (1..8).each { |f| assert_backends_agree(one_screen, frames: f) }
  end

  # A TIMER'S HANDLER IS NOT SETUP, however it reads on the page. It is written above the
  # game loop, like everything a program declares, and the console goes back into it many
  # times a second — so a sprite it moves moves, and the frame has to keep writing it. This
  # is the shape that makes "it runs before the loop, so it runs once" wrong.
  private def moved_by_a_timer
    built do
      screen :tiled
      image :hero, width: 16, height: 16, data: Array.new(256, RED)
      moved = sprite(:hero, at: [8, 40])
      timer(:tick, per_second: 60).on_tick { moved.x.add! 1 }
      game_loop { wait_vblank }
    end
  end

  def test_a_sprite_a_timer_moves_is_not_taken_for_a_still_one
    rom = assemble_rom(moved_by_a_timer, name: "TICK")
    v = assert_emulator_loads_rom(rom, frames: 30)

    assert_operator v.sprites(:hero).first.x, :>, 8,
                    "a timer's handler runs again and again, so what it moves must really move"
  end

  # A SCENE NUMBERED -1, which is a value the frame's own bookkeeping must not be confused
  # by. A program numbers its states however it likes, so "nothing has been written yet"
  # cannot be said as a number and has to be kept apart from them. Get it wrong and the still
  # sprites are never written at all: a title screen blank for ever, with nothing in the
  # program to point at.
  private def a_scene_numbered_below_nothing
    built do
      screen :tiled
      image :sign, width: 16, height: 16, data: Array.new(256, YELLOW)
      var :state, -1
      scene(:title) { sprite(:sign, at: [40, 40]) }
      game_loop { case_var(:state) { when_val(-1, :title) } }
    end
  end

  def test_a_still_sprite_shows_in_a_scene_numbered_below_nothing
    assert_backends_agree(a_scene_numbered_below_nothing, frames: 4)
  end

  # CHANGING THE SCREEN WIPES THE SPRITE TABLE, which is the one thing that can take a still
  # sprite away without the program doing anything. A bitmap title handing over to a tiled
  # game clears the table on the way in, so what was written once has to be written once more
  # — and nothing in the program says so.
  private def bitmap_title_then_tiled_game
    built do
      image(:hero, "#" => :green) { "########\n" * 8 }
      screen :bitmap
      var :state, 0
      scene :title do
        clear_screen :red
        pressed(:start).then { set! :state, 1 }
      end
      scene :play do
        screen :tiled
        sprite :hero, at: [100, 76]
      end
      game_loop do
        wait_vblank
        case_var :state do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
  end

  def test_a_still_sprite_comes_back_after_the_screen_changes
    rom = assemble_rom(bitmap_title_then_tiled_game, name: "SWAP")
    v = assert_emulator_loads_rom(rom, frames: 4, keys: KEY_START)
    v.step(8)

    assert v.green?(103, 79), "the tiled game's sprite must be drawn once the screen has changed"
  end
end

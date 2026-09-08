# frozen_string_literal: true

require_relative "test_helper"

# THE SOUNDS THE GAME MAKES, and which moment makes which.
#
# Read off the interpreter's own mixer, which can say WHICH samples are sounding rather than only
# that a noise happened — so these assert that firing the pistol plays the pistol and not merely
# that something was heard. A couple at the end put the same thing on the cartridge.
#
# THE CLIPS ARE A STUB rather than the fixture release's, and for one reason: length. A real
# chunk of the fixture is a tenth of a second, so whether a sound is still sounding depends on
# reading the mixer within a few frames of the moment that started it, and a test that has to
# guess a frame is measuring the guess. These clips last half a second, so the reading is taken
# comfortably inside them. Reading a real VSWAP is Vswap's own business and is tested there —
# except for the one test below that walks the whole road on the fixture's own file.
class TestSounds < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Sounds = Wolf3D::Sounds
  Guards = Wolf3D::Guards
  Release = Wolf3D::Fixture::Release

  SIDE = 16
  FLOOR = Wolf3D::Level::FLOOR
  WALL = Release::WALL
  RATE = 7000
  HALF_A_SECOND = RATE / 2

  # A stand-in for the player's copy of the sounds: as many chunks as asked for, each half a
  # second of a tone of its own.
  Clip = Struct.new(:pcm, :rate, :length)

  class Chunks
    def initialize(count) = @count = count
    def sound_count = @count

    def sound(index)
      pcm = Array.new(HALF_A_SECOND) { |i| (Math.sin(i * (index + 1) * 0.01) * 100).round }
      Clip.new(pcm, RATE, pcm.length)
    end
  end

  # Every chunk the game knows how to want.
  ALL = Sounds::DEATH_SCREAMS.max + 1

  # ---------------------------------------------------------------- the player

  # A GUARD HAS TO BE ON THE FLOOR for the pistol to fire at all — the shot is the guards' minds'
  # business, and a floor with nobody on it has no mind. That is the game as it stands rather than
  # anything to do with sound.
  def test_firing_the_pistol_plays_the_pistol
    heard = heard_during(40, guards: [[11, 8, :west]]) { |f| f == 4 ? [:b] : [] }

    assert_includes heard, name_of(Sounds::PISTOL)
  end

  def test_a_build_with_no_copy_of_the_game_is_silent_and_still_builds
    level = arena(guards: [[11, 8, :west]])
    run = Reference.new.input_each_frame { |f| f == 4 ? [:b] : [] }
                   .run(view_of(level, chunks: nil), frames: 8, max_steps: 4_000_000)

    assert_empty run.active_samples, "nothing to play, and nothing broken by having nothing"
  end

  # A COPY THAT HOLDS FEWER SOUNDS THAN THE GAME KNOWS ABOUT still plays the ones it has. The
  # shareware release ships fewer chunks than the registered one, and a cartridge that refused to
  # build over a missing scream would be the wrong answer.
  def test_a_copy_missing_some_sounds_plays_the_ones_it_has
    heard = heard_during(40, guards: [[11, 8, :west]],
                             chunks: Chunks.new(Sounds::PISTOL + 1)) { |f| f == 4 ? [:b] : [] }

    assert_includes heard, name_of(Sounds::PISTOL), "the pistol is in every copy"
    assert_empty heard - [name_of(Sounds::PISTOL), name_of(Sounds::NOTICES_YOU)],
                 "and nothing this copy does not hold"
  end

  # ---------------------------------------------------------------- the guards

  # "Halt!" is the one sound that tells you something you could not otherwise know.
  def test_a_guard_who_notices_you_shouts
    assert_includes heard_during(200, guards: [[11, 8, :west]]) { [] }, name_of(Sounds::NOTICES_YOU)
  end

  def test_a_guard_who_fires_is_heard
    assert_includes heard_during(300, guards: [[11, 8, :west]]) { [] }, name_of(Sounds::GUARD_FIRES)
  end

  # ...AND ONE OF HIS SCREAMS, whichever the roll picked. Held as "one of them" rather than a
  # named one, because which it is is the whole point of there being several.
  def test_a_guard_who_dies_screams
    heard = heard_during(120, guards: [[11, 8, :west]], drawn: true) { |f| f.even? ? [:b] : [] }
    screams = Sounds::DEATH_SCREAMS.map { |n| name_of(n) }

    refute_empty heard & screams, "expected one of #{screams.inspect}, heard #{heard.inspect}"
  end

  # ---------------------------------------------------------------- the level

  # The fixture floor has a door in the wall the player starts with their back to.
  def test_opening_a_door_is_heard_and_a_door_already_open_is_not_heard_again
    opening = walk_at_the_door(frames: about_turn + 46)
    later = walk_at_the_door(frames: about_turn + 130)

    assert_includes opening.active_samples, name_of(Sounds::DOOR_OPENS), "the door opening"
    refute_includes later.active_samples, name_of(Sounds::DOOR_OPENS),
                    "and not opening again while it stands open"
  end

  # ...AND SWINGS SHUT AFTER STANDING OPEN, which is a fixed count of frames later. Standing in
  # the doorway tops that count back up, so the player walks at the door and then stops short of
  # it: the script holds the button only until the door is open.
  def test_a_door_that_has_stood_open_long_enough_is_heard_swinging_shut
    shuts = about_turn + 46 + FP::DOOR_LINGER
    heard = (shuts...(shuts + 40)).step(LOOK_EVERY)
                                  .flat_map { |n| walk_at_the_door(frames: n).active_samples }.uniq

    assert_includes heard, name_of(Sounds::DOOR_SHUTS)
  end

  # ---------------------------------------------------------------- several at once

  # THE POINT OF A MIXER, and the bead's own question: several sounds at once sound like several
  # at once rather than like one winning. A guard shouting, a guard firing and a pistol is what a
  # firefight is, and the interpreter counts the voices that really sounded together.
  def test_a_firefight_sounds_several_voices_at_once
    run = play_it(frames: 300, guards: [[11, 8, :west], [11, 6, :west]]) { |f| f % 8 == 0 ? [:b] : [] }

    assert_operator run.peak_voices, :>=, 3,
                    "a firefight should stack voices, not cut them off — peak was #{run.peak_voices}"
  end

  # ...AND THE PISTOL IS THE ONE THAT DOES NOT STACK. The original keeps a mixer channel for the
  # player's own weapon so a new shot replaces the last; without that, tapping the trigger fills
  # every voice with pistol and there is none left for anything else.
  def test_tapping_the_trigger_does_not_fill_the_mixer_with_pistol
    run = play_it(frames: 40, guards: [[11, 8, :west]]) { |f| f.even? ? [:b] : [] }
    pistols = run.active_samples.count { |n| n == name_of(Sounds::PISTOL) }

    assert_equal 1, pistols, "one pistol voice however fast you tap, got #{run.active_samples.inspect}"
  end

  # ---------------------------------------------------------------- and on the console

  # THE WHOLE ROAD ON A REAL FILE: the fixture's own VSWAP, read as a release, converted, built
  # into a cartridge, and the console really makes a noise.
  def test_the_cartridge_reads_the_games_own_file_and_makes_a_noise
    release = Release.new(sounds: ALL)
    vswap = Wolf3D::Vswap.new(release.files["VSWAP"])
    program = view_of(arena(guards: [[11, 8, :west]]), chunks: vswap, drawing: true)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "SOUND", code: "ZSND", maker: "01")

    firing = ->(frame) { frame.between?(8, 9) ? RubyGBA::Constants::KEY_B : 0 }
    console = RubyGBA::Verifier.new(rom, frames: 40, keys: firing)

    assert console.sound?, "the cartridge should have made a noise"
  end

  private

  def fixture = @fixture ||= Release.new
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])
  def palette = Wolf3D::Palette.game

  def name_of(chunk) = :"sound_#{chunk}"
  def sounding(run) = run.active_samples.uniq

  def arena(guards: [])
    cells = Array.new(SIDE * SIDE, FLOOR)
    standing = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        cells[(y * SIDE) + x] = WALL if x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
      end
    end
    standing[(8 * SIDE) + 8] = Wolf3D::Level::FACINGS.key(:east)
    guards.each { |x, y, way| standing[(y * SIDE) + x] = Guards::STANDING + Guards::FACINGS.index(way) }
    Wolf3D::Level.new(name: "Sounds", width: SIDE, height: SIDE, walls: cells, things: standing)
  end

  def view_of(level, chunks: Chunks.new(ALL), drawing: false)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    scenery = Wolf3D::Scenery.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette,
                                    (guards.pictures + scenery.pictures +
                                     Wolf3D::Pickups.pictures(guards)).uniq.sort)

    RubyGBA.game("SOUND", code: "ZSND", maker: "01") do
      screen :bitmap, tear_free: true
      view = FP.new(build: self, level: level, atlas: atlas, doors: doors, pushwalls: pushwalls,
                    guards: guards, things: things, scenery: scenery, vswap: chunks)
      game_loop { drawing ? view.update : view.play }
    end.program
  end

  # A GUN IS HEARD WHETHER OR NOT IT HITS, so nothing here needs drawing except the question about
  # a man SCREAMING — that noise is made where the damage is done, and a shot only goes to a man
  # the renderer put on the screen. So one test draws and the rest stay cheap.
  def play_it(frames:, guards: [], chunks: Chunks.new(ALL), drawn: false, &script)
    Reference.new.input_each_frame(&script)
             .run(view_of(arena(guards: guards), chunks: chunks, drawing: drawn), frames: frames,
                  max_steps: drawn ? frames * 50_000 : 8_000_000)
  end

  # WHAT SOUNDED AT ANY POINT over a run, rather than what happens to be sounding at the end.
  #
  # The interpreter hands back the state a run FINISHED in, so asking whether a sound was ever
  # made means looking while it is still going — and a test that picks one frame to look at is
  # really testing that guess. This looks at a spread of them instead. The step is under the
  # length of a clip (half a second, thirty frames), so nothing can start and finish between two
  # looks and be missed.
  LOOK_EVERY = 20

  def heard_during(frames, **opts, &script)
    (LOOK_EVERY..frames).step(LOOK_EVERY)
                        .flat_map { |n| play_it(frames: n, **opts, &script).active_samples }.uniq
  end

  # --- the fixture floor, which is the one with a door on it -----------------------

  def fixture_level
    @fixture_level ||= Wolf3D::Maps.new(maphead: fixture.files["MAPHEAD"],
                                        gamemaps: fixture.files["GAMEMAPS"])[0]
  end

  def about_turn = ((FP::TURN / 2) / FP::TURN_SPEED.to_f).ceil

  # Turn about, walk at the door in the room's south wall, open it — AND THEN STAND STILL. Walking
  # on into the doorway tops the door's count back up for as long as you stand there, which is the
  # game refusing to shut a door on you, so a player who kept walking would never hear one shut.
  def walk_at_the_door(frames:)
    turn = about_turn
    press = turn + 40
    Reference.new.input_each_frame do |f|
      next [:left] if f <= turn
      next %i[up a] if f == press
      next [:up] if f < press

      []
    end.run(view_of(fixture_level), frames: frames, max_steps: 8_000_000)
  end
end

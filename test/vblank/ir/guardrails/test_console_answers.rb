# frozen_string_literal: true

require "test_helper"

# A game hears, while it builds, what its console does with what it asks for (Console::Answers,
# read for the console the build is for): an error for what the hardware cannot do, and a warning
# for a row with more sprites than it draws. The Advance does all of it, so a game built for the
# Advance hears none of it.
class TestConsoleAnswers < Minitest::Test
  CHECK = VBlank::IR::Guardrails::Checks::ConsoleAnswers.new

  TURNING = VBlank.game("TURNING", consoles: %i[gba gbc]) do
    screen :rotozoom
    image(:dark, "#" => :black) { "########\n" * 8 }
    tiles :floor, "#" => :dark
    board = background :board, tiles: :floor, map: ["#" * 4] * 4
    game_loop { board.rotate 30 }
  end

  # A sprite turned by a little more each pass: its angle is worked out as the game runs.
  SPINNING = VBlank.game("SPINNING", consoles: %i[gba gbc]) do
    screen :tiled
    image(:ship, "#" => :white) { "########\n" * 8 }
    ship = sprite :ship, at: [40, 40]
    game_loop { ship.turn 4 }
  end

  SHOULDERS = VBlank.game("SHOULDERS", consoles: %i[gba gbc]) do
    count = var :count, 0
    game_loop { held(:l).then { count.add! 1 } }
  end

  # Any button at all is not a button a console can lack.
  ANY_BUTTON = VBlank.game("ANYBUTTON", consoles: %i[gba gbc]) do
    count = var :count, 0
    game_loop { pressed(:any).then { count.add! 1 } }
  end

  CROWDED = VBlank.game("CROWDED", consoles: %i[gba gbc]) do
    screen :tiled
    draw_text "ABCDEFGHIJKL", 4, 20, :white
    game_loop { wait_vblank }
  end

  # A layer seen through by an amount written in the program is told to the console once, at boot,
  # so there is no step of the game's for it: only the layers' declaration says it.
  GHOST = VBlank.game("GHOST", consoles: %i[gba gbc]) do
    screen :tiled
    image(:ghost, "#" => :white) { "########\n" * 8 }
    layers :world, :ghosts
    layer(:ghosts, transparency: 40) { sprite :ghost, at: [40, 40] }
    game_loop { wait_vblank }
  end

  # A voice clip played once, as it was recorded: the Color plays that.
  CLIP = VBlank.game("CLIP", consoles: %i[gba gbc]) do
    hello = sample :hello, pcm: [60, -60] * 200
    hello.play
    game_loop { wait_vblank }
  end

  # ...and each part of playing a recording that a clip player has no way to do, a game apiece.
  CLIP_PARTS = {
    loop: VBlank.game("CLIPLOOP", consoles: %i[gba gbc]) do
      sample(:hum, pcm: [60, -60] * 200).play(loop: true)
      game_loop { wait_vblank }
    end,
    pitch: VBlank.game("CLIPNOTE", consoles: %i[gba gbc]) do
      sample(:hum, pcm: [60, -60] * 200).play(pitch: :E4)
      game_loop { wait_vblank }
    end,
    volume: VBlank.game("CLIPVOL", consoles: %i[gba gbc]) do
      sample(:hum, pcm: [60, -60] * 200).play(volume: :three_quarter)
      game_loop { wait_vblank }
    end,
    envelope: VBlank.game("CLIPSHAPE", consoles: %i[gba gbc]) do
      sample(:hum, pcm: [60, -60] * 200, envelope: { release: 0.2 }).play
      game_loop { wait_vblank }
    end,
    wave: VBlank.game("CLIPWAVE", consoles: %i[gba gbc]) do
      enable_sound
      sample(:hum, pcm: [60, -60] * 200).play
      wave :triangle, 440
      game_loop { wait_vblank }
    end
  }.freeze

  # A song with a part on the wave voice beside a recording: the part stands aside while the
  # recording plays, so the Color plays both.
  CLIP_AND_SONG = VBlank.game("CLIPSONG", consoles: %i[gba gbc]) do
    enable_sound
    song(:pad) { voice(:low, plays: :wave) { |v| v.note :A4, :whole } }
    play_song :pad
    sample(:hum, pcm: [60, -60] * 200).play
    game_loop { wait_vblank }
  end

  private def findings(game, console) = CHECK.detect(game.program(console: console))

  def test_a_songs_wave_part_beside_a_recording_works_on_the_color
    assert_empty findings(CLIP_AND_SONG, :gbc)
  end

  def test_a_recording_played_once_as_recorded_works_on_the_color
    assert_empty findings(CLIP, :gbc)
  end

  # Each is one error, naming what the line asks for; the Advance's build hears none of them.
  def test_what_a_clip_player_cannot_do_is_refused_on_the_color
    said = { loop: /`loop: true`/, pitch: /`pitch:`/, volume: /three quarters/, envelope: /`envelope:`/,
             wave: /wave voice/ }
    CLIP_PARTS.each do |part, game|
      found = findings(game, :gbc)

      assert_equal [:error], found.map(&:severity), part.to_s
      assert_match said.fetch(part), found.first.message
      assert_match(/one recording at a time/, found.first.message)
      assert_empty findings(game, :gba), part.to_s
    end
  end

  def test_a_layer_seen_through_by_a_fixed_amount_is_refused_in_plain_words
    found = findings(GHOST, :gbc)

    assert_equal [:error], found.map(&:severity)
    assert_match(/`transparency:`/, found.first.message)
  end

  # Nothing is shown differently on the Color: a turning screen, and the line that turns its
  # background, are each refused.
  def test_a_turning_screen_and_a_turned_background_are_refused
    found = findings(TURNING, :gbc)

    assert_equal %i[error error], found.map(&:severity)
    assert(found.any? { |finding| finding.message.include?("cannot turn or resize a background") })
  end

  def test_a_turning_sprite_is_refused_naming_what_the_color_lacks
    found = findings(SPINNING, :gbc)

    assert_equal [:error], found.map(&:severity)
    assert_match(/cannot turn or resize a sprite/, found.first.message)
    assert_empty findings(SPINNING, :gba)
  end

  def test_a_shoulder_button_is_refused_in_plain_words
    found = findings(SHOULDERS, :gbc)

    assert_equal [:error], found.map(&:severity)
    assert_match(/:l button/, found.first.message)
    assert_match(/no shoulder buttons/, found.first.message)
  end

  def test_any_button_is_not_refused
    assert_empty findings(ANY_BUTTON, :gbc)
  end

  def test_a_row_of_more_than_ten_sprites_is_named
    found = findings(CROWDED, :gbc)

    assert_equal [:warning], found.map(&:severity)
    assert_match(/row 20/, found.first.message)
    assert_match(/10 on any one row/, found.first.message)
  end

  def test_the_advances_build_hears_nothing
    [TURNING, SPINNING, SHOULDERS, CROWDED, GHOST].each { |game| assert_empty findings(game, :gba) }
  end

  def test_a_color_build_stops_on_a_refusal
    error = assert_raises(VBlank::ROMError) do
      SHOULDERS.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    end

    assert_match(/stopped/, error.message)
  end
end

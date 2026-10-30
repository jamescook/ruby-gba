# frozen_string_literal: true

require "test_helper"

# A COLOR GAME'S SONGS IN THE CARTRIDGE'S BANKS (GBC::Music). The part of a Color cartridge that is
# always in view holds 16384 bytes, the framework's own code among them, and every song is kept
# there while they fit. A game with more music than that has its songs' notes kept in the banks
# instead, and the player puts a song's bank in view as it reads it. The run checks the cartridge
# against the interpreter after every pass, the sound log among what it compares.
class TestGBCMusic < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  # A note's pitch a sixteenth long, then the next: a tune that never repeats a bar.
  PITCHES = %i[C4 D4 E4 F4 G4 A4 B4 C5 D5 E5 F5 G5].freeze

  # Notes enough in each part that one part fills most of a bank: every part's notes start a bank
  # of their own, so two songs' notes are at one address in two banks.
  LONG = 1800

  # +songs+ songs of +notes+ sixteenths on two square voices, then +game+ — the game loop, handed
  # the frame count — after them.
  private def long_songs(songs: 3, notes: LONG, &game)
    pitches = PITCHES
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      enable_sound
      songs.times do |s|
        song :"tune#{s}" do
          tempo 240
          voice(:lead) { |v| notes.times { |n| v.note pitches[(n + s) % pitches.length], :sixteenth } }
          voice(:harmony) { |v| notes.times { |n| v.note pitches[(n * 5) % pitches.length], :sixteenth } }
        end
      end
      tick = var :tick, 0
      instance_exec(tick, &game)
    end
    b.finalize_program
    b.program
  end

  # Where each song's lead notes went in the cartridge: [bank, address], by song number.
  private def lead_notes_placed(program, songs)
    code = GBC.new.build(program).built.code
    (0...songs).map { |s| code.fetch("music_notes_#{s}_0_first").then { |place| [place.bank, place.address] } }
  end

  private def voice_entries(program, frames) = game_player.run(program, frames: frames).audio.count { |entry| entry.first == :voice }

  # Two parts of a sixteenth a note at this tempo start ten notes each in forty frames, the second
  # song's and then the third's, which each start a bank.
  def test_songs_bigger_than_the_part_always_in_view_play_as_the_interpreter_plays_them
    program = long_songs do |tick|
      play_song :tune1
      game_loop do
        tick.add! 1
        (tick == 20).then { play_song :tune2 }
      end
    end
    placed = lead_notes_placed(program, 3)

    assert placed.all? { |bank, _| bank.positive? }, "every song's notes in a bank"
    assert_equal placed[1].last, placed[2].last, "the two songs' notes at one address, in two banks"
    assert_operator voice_entries(program, 40), :>=, 18
  end

  # A SONG THAT COMES ROUND, kept in a bank beside long ones: its notes are read again from its
  # bank once it has played to its end.
  def test_a_song_kept_in_a_bank_comes_round
    program = long_songs do |tick|
      song :short do
        tempo 240
        voice(:lead) { |v| PITCHES.first(4).each { |pitch| v.note pitch, :sixteenth } }
      end
      play_song :short
      game_loop { tick.add! 1 }
    end

    assert_operator voice_entries(program, 40), :>=, 9
  end

  # A TUNE STARTED WHERE IT IS NAMED (`this_frame: true`) takes its first frame there, its bank put
  # in view outside the frame's interrupt.
  def test_a_song_kept_in_a_bank_starts_on_the_frame_it_is_named
    program = long_songs do |tick|
      game_loop do
        tick.add! 1
        (tick == 5).then { play_song :tune1, this_frame: true }
      end
    end

    assert_operator voice_entries(program, 20), :>=, 8
  end

  # A SOUND EFFECT over a song kept in a bank: its notes stay in the part always in view, and it
  # takes its voice from the song and gives it back.
  def test_a_sound_effect_plays_over_a_song_kept_in_a_bank
    score = VBlank::Audio::Score
    zap = score.new(tempo: 120, parts: [score::Part.new(notes: [score::Note.new(at: 0, key: :E5, length: 12)])])
    program = long_songs do |tick|
      sfx = sound_effects :sfx, { zap: zap }
      play_song :tune0
      game_loop do
        tick.add! 1
        (tick == 10).then { sfx.play :zap }
      end
    end

    assert_operator voice_entries(program, 30), :>=, 12
  end
end

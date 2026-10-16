# frozen_string_literal: true

require "test_helper"
require "sound_comparison"

# A SONG THAT PLAYS ONCE, on the desktop build: it lasts exactly its length, its parts go quiet
# on the frame after its last, and it stays ended while the game goes on naming it — until the
# game stops the music and names it again, or names another song first. The rule every backend
# keeps is at IR::Tunes.plays_once?, and the tests that pin it on the interpreter and the
# cartridge are in test/ruby_gba/audio/test_scores.rb.
#
# The games here are built by hand, out of IR::Build, and not through the DSL. A song says it
# plays once only in a list of songs picked by number (`songs`), which the desktop build cannot
# play yet; `play_song` plays the same node, so a song node that says it is handed straight to
# that.
class TestNativeSongPlaysOnce < Minitest::Test
  include SoundComparison
  include RubyGBA::IR::Build

  HeadlessRun = RubyGBA::IR::Backends::Native::HeadlessRun
  Part = RubyGBA::Audio::Music::Part

  C4 = 262
  E4 = 330
  G4 = 392

  # Two notes ten frames apart in a song twenty frames long, which says it plays once.
  private def two_notes_once(**said)
    song(:jingle, total_frames: 20, events: [[0, C4], [10, E4]], plays_once: true, **said)
  end

  # A game that counts its passes in :pass and runs +each_pass+ on every one, with these songs.
  # Each pass waits for the screen first, as a `game_loop` does: so what the game says on pass 1
  # is taken up by the player as frame 2 starts.
  private def game(songs, *each_pass)
    program(enable_sound, *songs, set(:pass, 0), loop_(wait_vblank, add(:pass, 1), *each_pass))
  end

  private def on_pass(number, *body) = if_(binop(:==, :pass, number), *body)

  # Which notes sounded on which frame, read off a run's sound log as it grows.
  private def notes_by_frame(player, program, frames)
    heard = {}
    logged = 0
    player.each_vblank do |frame|
      fresh = player.audio.drop(logged).select { |entry| entry[0] == :note }.map(&:last)
      logged = player.audio.size
      heard[frame] = fresh unless fresh.empty?
    end
    player.run(program, frames: frames)
    heard
  end

  # The desktop build plays +wanted+ — the notes worked out by hand, by the frame each sounds on —
  # and agrees with the interpreter on every entry of the sound log at every frame.
  private def assert_plays(wanted, program, frames:)
    assert_equal wanted, notes_by_frame(Reference.new, program, frames), "the interpreter, which is the answer key"
    assert_equal wanted, notes_by_frame(HeadlessRun.new, program, frames)
    assert_native_matches_reference program, frames: frames
  end

  # It ends where its length says and is not heard again, though the game goes on naming it
  # every pass: naming the song already named changes nothing, whether or not it has ended.
  def test_a_song_that_plays_once_does_not_come_round
    program = game([two_notes_once], play_song(:jingle))

    assert_plays({ 2 => [C4], 12 => [E4] }, program, frames: 70)
  end

  # Its parts go quiet on the frame after its last, the way they do when the game stops the
  # music: named on pass 1 and taken up at frame 2, its twenty frames are 2 to 21.
  def test_its_parts_go_quiet_on_the_frame_after_its_last
    program = game([two_notes_once], play_song(:jingle))
    player = HeadlessRun.new
    stopped = []
    player.each_vblank { |frame| stopped << frame if player.audio.count([:stop_music]) > stopped.length }
    player.run(program, frames: 40)

    assert_equal [22], stopped
  end

  # A song that has ended is started the way any song is started over: stop the music and name
  # it, in the same pass...
  def test_a_song_that_ended_starts_over_after_a_stop
    program = game([two_notes_once], on_pass(40, stop_music), play_song(:jingle))

    assert_plays({ 2 => [C4], 12 => [E4], 41 => [C4], 51 => [E4] }, program, frames: 70)
  end

  # ...or a later one.
  def test_a_song_that_ended_starts_over_when_named_some_passes_after_a_stop
    program = game([two_notes_once],
                   if_(binop(:<, :pass, 40), play_song(:jingle)),
                   on_pass(40, stop_music),
                   if_(binop(:>=, :pass, 45), play_song(:jingle)))

    assert_plays({ 2 => [C4], 12 => [E4], 46 => [C4], 56 => [E4] }, program, frames: 70)
  end

  # ...or name another song first.
  def test_a_song_that_ended_starts_over_after_another_song
    other = song(:other, total_frames: 30, events: [[0, G4]])
    program = game([two_notes_once, other],
                   if_(binop(:<, :pass, 40), play_song(:jingle)),
                   if_(binop(:and, binop(:>=, :pass, 40), binop(:<, :pass, 45)), play_song(:other)),
                   if_(binop(:>=, :pass, 45), play_song(:jingle)))

    assert_plays({ 2 => [C4], 12 => [E4], 41 => [G4], 46 => [C4], 56 => [E4] }, program, frames: 70)
  end

  # A stop said while it is still playing, and the song named again on the same pass, starts it
  # from its first note and it then plays to its end once more.
  def test_a_stop_and_a_play_part_way_through_plays_it_again_from_the_top
    program = game([two_notes_once], on_pass(15, stop_music), play_song(:jingle))

    assert_plays({ 2 => [C4], 12 => [E4], 16 => [C4], 26 => [E4] }, program, frames: 60)
  end

  # A song that says it plays once and names a frame to loop from still ends.
  def test_a_song_that_plays_once_ends_even_when_it_names_a_loop_frame
    program = game([two_notes_once(loop_frame: 10)], play_song(:jingle))

    assert_plays({ 2 => [C4], 12 => [E4] }, program, frames: 70)
  end

  # Every one of the console's own voices is let go when it ends: a part on a square voice, a
  # pad on the wave voice, and a hiss on the noise voice that would otherwise still be fading.
  # The speaker says so too, voice by voice, as the cartridge's does.
  def test_every_voice_goes_quiet_when_it_ends
    parts = [Part.new(events: [[0, C4]]), Part.new(events: [[0, C4]], wave: :triangle),
             Part.new(events: [[0, 4000], [10, 2000]], noise: true, decay: :slow)]
    program = game([song(:jingle, total_frames: 20, voices: parts, plays_once: true)], play_song(:jingle))

    assert_plays({ 2 => [C4, C4, 4000], 12 => [2000] }, program, frames: 50)
    assert_native_sounds_like_the_console program, frames: 50, voices: %i[square1 wave noise]
  end

  # The music volume reaches it while it plays, and has nothing of it to reach once it has ended.
  #
  # The volume is the variable the game keeps it in (IR::Tunes::LEVEL), full at sixteen: halved
  # on pass 10, while the one note is held, and halved again on pass 30, after the end.
  def test_the_music_volume_reaches_it_until_it_ends
    level = RubyGBA::IR::Tunes::LEVEL
    held = song(:jingle, total_frames: 20, events: [[0, C4]], plays_once: true)
    program = game([held, set(level, RubyGBA::IR::Tunes::FULL_LEVEL)],
                   play_song(:jingle), on_pass(10, set(level, 8)), on_pass(30, set(level, 4)))
    turned = HeadlessRun.new.run(program, frames: 50).audio.select { |entry| entry[0] == :loudness }

    assert_equal [[:loudness, 1, 12], [:loudness, 1, 6]], turned, "as its note starts at volume 12, and once more at half"
    assert_native_matches_reference program, frames: 50
  end

  # What comes out of the speaker says the same as the cartridge's: the two notes, then nothing
  # for the rest of the run, and the song heard again from its first note after a stop.
  #
  # Named on the first pass, the song is taken up as frame 2 starts and sounds through the twenty
  # frames from there, 2 to 21; stopped and named on pass 60, it sounds again from 61 to 80.
  def test_it_sounds_like_the_consoles_and_is_silent_after_it
    program = game([two_notes_once], on_pass(60, stop_music), play_song(:jingle))
    native = native_voice(program, :square1, frames: 110)
    loud = (0...native.frame_count).select { |frame| native.loudness(frame) >= SoundComparison::HEARD }

    assert_equal [*2..21, *61..80], loud, "heard for its twenty frames, twice, and silent between and after"
    assert_native_sounds_like_the_console program, frames: 110, voices: [:square1]
  end
end

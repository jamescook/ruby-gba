# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# A game built as Ruby and played live a pass at a time through a device: the session shows the
# device each pass's picture, asks it which buttons are held and whether to stop, and keeps the
# frames on the console's beat by its clock. These play through the headless device, whose clock moves only
# when the test says a pass took so long, so nothing here waits for real time to pass.
class TestSession < Minitest::Test
  Session = VBlank::Live::Session
  Headless = VBlank::Live::Headless

  private def game(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  def test_the_device_is_shown_every_pass_the_game_draws
    device = Headless.new(frames: 3)
    Session.new(game { game_loop { pixel 2, 1, :red } }).play(device)

    assert_equal 3, device.pictures.size
    picture = device.pictures.last
    assert_equal Color.resolve(:red), picture.pixels[(1 * picture.width) + 2]
  end

  # The buttons held on a frame are read as it ends, for the pass that starts then: so A held
  # on the second and third frames is seen by the third and fourth passes, as on the console.
  def test_buttons_held_on_a_frame_reach_the_pass_after_it
    device = Headless.new(frames: 5, buttons: { 2 => [:a], 3 => [:a] })
    Session.new(game { game_loop { held(:a).then { pixel 0, 0, :red }.else { pixel 0, 0, :blue } } }).play(device)

    seen = device.pictures.map { |picture| Color.resolve(:red) == picture.pixels[0] ? :a : :none }
    assert_equal %i[none none a a none], seen
  end

  # A machine too slow to keep up: every pass takes two of the console's frames. The game as Ruby
  # counts one frame a pass, as every lowered game does today, so it runs at half speed while the
  # clock says two frames went by each time; a console that missed every other frame would have
  # moved it on two. (The first picture is the frame the game sets itself up in, before its loop
  # first runs, so it has no mark.)
  def test_a_pass_that_takes_two_frames_moves_the_game_on_one
    program = counting_game
    device = Headless.new(frames: 4, pass_seconds: 2 * frame_seconds(program))
    rate = Session.new(program).play(device)

    assert_equal [nil, 1, 2, 3], device.pictures.map { |picture| marked_frame(picture) }
    assert_equal 8, rate.frames
  end

  # A machine faster than the console waits for each frame to end, so a pass is one frame,
  # the fourth picture is not shown before the fourth frame has ended, and the play went at
  # exactly the console's speed.
  def test_a_pass_quicker_than_a_frame_waits_for_the_frame_to_end
    program = counting_game
    frame = frame_seconds(program)
    device = Headless.new(frames: 4, pass_seconds: frame / 4)
    rate = Session.new(program).play(device)

    assert_equal [nil, 1, 2, 3], device.pictures.map { |picture| marked_frame(picture) }
    assert_operator device.now, :>=, 4 * frame
    assert_in_delta 1 / frame, rate.passes_per_second, 0.001
  end

  # The play says how fast it went, by the device's clock: four pictures, each pass two
  # frames, is eight of the console's frames in eight frames' time — the game at full speed,
  # its picture at half.
  def test_the_play_says_how_many_passes_and_frames_a_second_it_reached
    program = counting_game
    frame = frame_seconds(program)
    rate = Session.new(program).play(Headless.new(frames: 4, pass_seconds: 2 * frame))

    assert_equal [4, 8], [rate.passes, rate.frames]
    assert_equal 8 * frame, rate.seconds
    assert_in_delta 1 / frame, rate.frames_per_second, 0.001
    assert_in_delta 1 / (2 * frame), rate.passes_per_second, 0.001
  end

  # Played uncapped, for measuring, the session never waits for a frame to end: each pass starts
  # the moment the last one ends, the game moves on a frame a pass, and the rate is the machine's
  # own. Four passes of a quarter of a frame each are four times the console's speed.
  def test_an_uncapped_play_goes_as_fast_as_the_machine
    program = counting_game
    frame = frame_seconds(program)
    rate = Session.new(program, uncapped: true).play(Headless.new(frames: 4, pass_seconds: frame / 4))

    assert_equal [4, 4], [rate.passes, rate.frames]
    assert_in_delta 4 / frame, rate.passes_per_second, 0.001
  end

  # A play told how many passes to go on for stops there, whatever the device would say.
  def test_a_play_stops_after_the_passes_it_was_given
    device = Headless.new(frames: 100)
    rate = Session.new(game { game_loop { pixel 0, 0, :red } }, stop_after_passes: 3).play(device)

    assert_equal [3, 3], [device.pictures.size, rate.passes]
  end

  # A game that ends by itself ends the play, and says how far it got.
  def test_a_game_that_halts_ends_the_play
    device = Headless.new(frames: 100)
    rate = Session.new(game { repeat(3) { wait_vblank } }).play(device)

    assert_equal 3, device.pictures.size
    assert_equal 3, rate.passes
  end

  # A game's sound goes to the device with each picture: the samples of the frame the pass just
  # played, a frame's share of a second at the rate they were made at. The first frame is the one
  # the game sets itself up in, so a beep the loop's third pass starts is heard from the fourth
  # frame's sound on, and the three before are silent.
  def test_each_pass_hands_the_device_the_sound_of_its_frame
    program = game do
      enable_sound
      x = var :x, 0
      game_loop do
        (x == 2).then { beep 440, duty: :half, decay: :none, volume: 15 }
        x.add! 1
      end
    end
    device = Headless.new(frames: 5)
    Session.new(program).play(device)

    rate = device.sound_rate
    frame = frame_seconds(program)
    assert_equal 5, device.sounds.size
    device.sounds.each { |samples| assert_in_delta rate * frame, samples.size, 1 }
    assert_equal [true, true, true, false, false], device.sounds.map { |samples| samples.all?(&:zero?) }
  end

  # A game that saves to flash keeps its save in memory for the length of the play: the chip's
  # wipe finishes, and the copy reads back good two passes later.
  def test_a_game_that_saves_to_flash_reads_its_save_back
    builder = Builder.new(options: VBlank::Cartridge::Options.new(save_memory: 128))
    builder.instance_eval do
      hearts = var :hearts, 3
      files = save_data(:file, copies: 1) { keep hearts }
      pass = var :pass, 0
      game_loop do
        (pass == 0).then { files[0].save }
        (pass == 2).then { files[0].good?.then { pixel 0, 0, :green } }
        pass.add! 1
      end
    end
    builder.finalize_program
    device = Headless.new(frames: 6)
    Session.new(builder.program).play(device)

    assert_equal Color.resolve(:green), device.pictures.last.pixels[0]
  end

  # A game that does something its rules refuse stops the play with the error the interpreter raises.
  def test_a_game_that_goes_wrong_stops_the_play_with_a_program_error
    program = game do
      trail = list :trail, capacity: 1
      game_loop { trail.push 1 }
    end

    error = assert_raises(VBlank::IR::ProgramError) { Session.new(program).play(Headless.new(frames: 9)) }
    assert_match(/list :trail is full/, error.message)
  end

  # A game that marks how many frames it has seen: one red pixel on the top row, that many
  # pixels in.
  private def counting_game
    game do
      game_loop do
        clear_screen :black
        draw_rect_at frames_since_power_on, 0, 1, 1, :red
      end
    end
  end

  # How long one of the program's console's frames lasts, a little more than a sixtieth.
  private def frame_seconds(program) = program.described_console.frame_seconds

  private def marked_frame(picture)
    picture.pixels.first(picture.width).index(Color.resolve(:red))
  end
end

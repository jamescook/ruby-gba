# frozen_string_literal: true

require "test_helper"

# SOUND KEEPS ITS OWN TIME, whatever the game does.
#
# Everything a game moves is paced by its loop — the walking, the timers, the animation, the
# fades — so a game too heavy for a frame runs uniformly in slow motion, which is coherent and
# arguably the right thing on a handheld. SOUND CANNOT JOIN IN. It is played by a clock the game
# does not own: the hardware reads a sample every sample-clock tick, in real time, and a game
# that hands it sound more slowly than that simply runs out.
#
# So the mixer's refill rides on the screen's own interrupt rather than on a pass of the game
# loop. These are the tests of that, and they can only be console tests: the interpreter has no
# clock, so a pass there is always exactly one frame and there is no lateness to model.
class TestMixerKeepsTime < Minitest::Test
  RATE = 8000
  SLICE = (RATE + 59) / 60 # what the hardware plays in one frame
  LASTS = 10               # ...so a clip this many slices long should take ten frames

  # A square wave, loud enough that a frame with any of it in reads far above a silent one.
  TONE = Array.new(SLICE * LASTS) { |i| (i % 40) < 20 ? 100 : -100 }

  # Long enough to hear the whole clip several times over even at four frames a pass.
  FRAMES = 40

  # Anything above this is a frame with sound in it. The gap between a sounding frame and a
  # silent one is three orders of magnitude, so nothing turns on where exactly this sits.
  AUDIBLE = 1_000_000

  # HOW MUCH WORK MAKES A PASS LATE, measured rather than guessed — these are the counts that
  # give one, two, three and four frames to a pass on this emulator. The test asserts what it
  # actually got, so a change in the machine shows up as a failed assumption rather than as a
  # test quietly measuring nothing.
  BURNS = { 1 => 0, 2 => 20_000, 3 => 40_000 }.freeze

  # A game that plays one clip at the start and then burns +burn+ steps a pass.
  def late_game(burn)
    tone = TONE
    rate = RATE
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clip = sample :tone, pcm: tone, rate: rate
      started = var :started, 0
      spin = var :spin, 0
      passes = var :passes, 0
      game_loop do
        passes.add 1
        (started == 0).then do
          started.set 1
          clip.play
        end
        repeat(burn) { spin.add 1 }
      end
    end
    b.emit_pending_functions
    b.program
  end

  # Play it on the console and report how many frames a pass took and which frames had sound.
  def heard(burn)
    backend = GBA.new
    program = late_game(burn)
    rom = ROM.assemble(backend.lower(program), title: "MIXTIME", code: "ZMXT", maker: "01")
    console = assert_emulator_loads_rom(rom, frames: FRAMES, vars: backend.var_addresses)
    loud = console.audio_energy_by_frame.each_index.select do |n|
      console.audio_energy_by_frame[n] > AUDIBLE
    end
    { per_pass: FRAMES / console.var(:passes).to_f, frames: loud.length,
      first: loud.first, last: loud.last }
  end

  # THE ONE THAT MATTERS. A clip ten frames long takes ten frames to get through itself,
  # however long the game takes over a pass. Refilled once per pass instead, a game running at
  # two frames a pass took twenty — the clip's own play position only advances when the mixer
  # runs, so half of every sound was missing, every other slice.
  #
  # MEASURED AS TIME RATHER THAN AS LOUDNESS, and that is a decision worth its line. How much
  # noise came out is a weak signal here: the two output buffers sit next to each other in
  # memory, so a starved DMA runs off the end of one into whatever is beside it and keeps making
  # a sound — the fault is a stutter, not a silence, and a coarse look at the energy reads clean.
  # How long the clip takes to get through itself is the direct question and it has one answer.
  def test_a_clip_takes_the_same_time_however_late_the_game_is
    on_time = heard(BURNS.fetch(1))

    assert_in_delta 1.0, on_time[:per_pass], 0.1, "the control game should keep up"

    BURNS.each do |frames_a_pass, burn|
      late = heard(burn)

      assert_in_delta frames_a_pass, late[:per_pass], 0.2,
                      "burn #{burn} was meant to give #{frames_a_pass} frames a pass"
      assert_equal on_time[:frames], late[:frames],
                   "at #{frames_a_pass} frames a pass the clip sounded over #{late[:frames]} " \
                   "frames instead of #{on_time[:frames]} — the mixer is being starved"
    end
  end

  # ...AND A GAME THAT FITS IN A FRAME IS UNCHANGED, which is the other half of the promise: the
  # clip starts where it started and ends where it ended.
  def test_a_game_that_keeps_up_hears_exactly_what_it_did_before
    on_time = heard(BURNS.fetch(1))

    assert_operator on_time[:frames], :>=, LASTS, "a ten-frame clip should sound for ten frames"
    assert_operator on_time[:frames], :<=, LASTS + 3, "...and not much longer"
    assert_operator on_time[:first], :<=, 4, "starting within a frame or two of the play"
  end

  # ...AND THE INTERRUPT MUST NOT FIRE BEFORE THE MIXER IS READY, which is the other thing that
  # changed when the refill moved into it.
  #
  # The refill jumps into a routine that boot copies into the console's quick memory. Arm the
  # interrupt before that copy and the first frame can arrive while the memory still holds
  # whatever it held at power-on — the jump lands in it and never comes back. While the handler
  # was only counting frames this could not happen, so nothing said the order mattered.
  #
  # IT IS A RACE, so what decides it is how long boot takes to reach the copy — and the boot code
  # in between is what silences the sound buffers, which are a sample rate's worth of bytes each.
  # A high rate is the one that loses. Measured: the machine hung at 30,120 samples a second and
  # ran at 30,060, with nothing else changed at all. So this walks the rates rather than testing
  # one, and the highest of them is the one that matters.
  RATES = [8_000, 22_050, 32_768, 65_536].freeze

  def test_a_game_boots_and_keeps_running_at_any_sample_rate
    RATES.each do |rate|
      backend = GBA.new
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        passes = var :passes, 0
        sample(:v, pcm: [100, -100] * 400, rate: rate).play(loop: true)
        game_loop { passes.add 1 }
      end
      b.emit_pending_functions
      rom = ROM.assemble(backend.lower(b.program), title: "MIXBOOT", code: "ZMXB", maker: "01")
      console = assert_emulator_loads_rom(rom, frames: 30, vars: backend.var_addresses)

      assert_operator console.var(:passes), :>, 20,
                      "at #{rate}Hz the game loop stopped turning — the first frame's interrupt " \
                      "reached the mixer before boot had put it there"
      assert console.sound?, "at #{rate}Hz nothing came out"
    end
  end
end

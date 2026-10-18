# frozen_string_literal: true

# THE SOUND OF EVERY FRAME, ON BOTH BACKENDS, BYTE FOR BYTE.
#
# The interpreter works out every byte of sound the cartridge's mixer writes (Reference#mixed_sound),
# and this holds it to the cartridge. The cartridge keeps two buffers and mixes into the one that is
# not playing, so after each frame that one holds the newest slice; which one is playing it says in
# a variable of its own.
#
# The two backends do not start counting frames at the same moment — the console spends frames
# setting itself up before the game's first pass — so each list is taken from its first slice
# with any sound in it, and the two must agree from there for as long as both run. What that
# cannot see is the two being a frame apart on EVERYTHING; it does see one sound landing a frame
# late against another, which is what a test plays two sounds for.
module MixedSound
  # How many frames more the console is run than the interpreter, to cover the frames it spends
  # setting itself up before the game's first pass.
  CONSOLE_SETUP_FRAMES = 4

  # The newest slice after every frame the console shows, for +frames+ frames, with the buttons in
  # +presses+ (a frame number to the buttons down on it) held.
  def console_mixes(program, frames, presses: {})
    require_emulator!
    gba = RubyGBA::IR::Backends::GBA.new
    rom = RubyGBA::Cartridge::ROM.assemble(gba.lower(program), title: "MIXBYTES", built: gba.build_record(program))
    keys = ->(frame) { presses.fetch(frame, []).sum { |button| RubyGBA::Diagnostics::Verifier.const_get(:"KEY_#{button.upcase}") } }
    console = RubyGBA::Diagnostics::Verifier.new(rom, frames: 1, keys: keys, vars: gba.var_addresses)
    slice = console.sample_clock.samples_a_frame
    Array.new(frames) do
      newest = console.var(RubyGBA::IR::Backends::GBA::Mixer::MIX_FRONT).zero? ? gba.mix_buf1 : gba.mix_buf0
      bytes = (0...slice).map { |i| signed_byte(console.mem8(newest + i)) }
      console.step
      bytes
    end
  end

  # ...and the interpreter's, the same buttons on the same frames.
  def interpreted_mixes(program, frames, presses: {})
    RubyGBA::IR::Backends::Reference.new.input_each_frame { |frame| presses.fetch(frame, []) }
                                    .run(program, frames: frames).mixed_sound
  end

  # Both backends make the same bytes, from the first slice with sound in it, for at least
  # +at_least+ frames. On a native run the two are the game as C and the interpreter, frame for
  # frame from the same first frame, since neither spends frames setting itself up; on a
  # JavaScript run, the game as JavaScript and the interpreter, the same way.
  def assert_mixes_agree(program, frames: 24, presses: {}, at_least: frames / 2)
    return assert_native_mixes_agree(program, frames, presses, at_least) if RubyGBA::Testing.checked?

    from_sound = ->(slices) { slices.drop_while { |slice| slice.all?(&:zero?) } }
    interpreted = from_sound.call(interpreted_mixes(program, frames, presses: presses))
    console = from_sound.call(console_mixes(program, frames + CONSOLE_SETUP_FRAMES, presses: presses))
    compared = [interpreted.length, console.length].min

    assert_operator compared, :>=, at_least, "too few frames with sound in them to compare"
    compared.times { |n| assert_equal console[n], interpreted[n], "frame #{n + 1} of the sound" }
  end

  def assert_native_mixes_agree(program, frames, presses, at_least)
    native = game_player.input_each_frame { |frame| presses.fetch(frame, []) }.run(program, frames: frames).mixed_sound
    interpreted = interpreted_mixes(program, frames, presses: presses)

    from_sound = native.drop_while { |slice| slice.all?(&:zero?) }
    assert_operator from_sound.length, :>=, at_least, "too few frames with sound in them to compare"
    assert_equal interpreted, native
  end

  # The console's memory reads a byte back unsigned; the mix holds signed ones.
  def signed_byte(byte) = byte >= 128 ? byte - 256 : byte
end

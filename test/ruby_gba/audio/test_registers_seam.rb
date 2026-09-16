# frozen_string_literal: true

require_relative "../../test_helper"
require "prism"

# THE LINE THROUGH THE SOUND MODULE, which its own comment draws: the musical half is what a
# "beep" or a note means, and every backend reads it; Sound::Registers is the console's bit
# patterns, and only the backend that writes a real cartridge has any business there.
#
# The comment said that before this test did, and the comment was WRONG — twice. The headless
# interpreter was asking Registers how loud a wave note is, and a guardrail that runs before
# any cartridge exists was asking it for the lowest note a square voice reaches. Neither wanted
# an encoding. Both wanted a LIMIT: the wave voice has five loudnesses, the square voices stop
# at 64 Hz. Those are facts about the console every backend has to agree on, so they moved out
# to the shared half where anything may read them.
#
# Nothing about that drift was visible. Both files kept working, the comment kept claiming the
# opposite, and the next person to reach across would have had the same reason and the same
# silence. So the claim is a test now: reach into Registers from outside the GBA lowering and
# this fails, naming the file and what it asked for.
class TestRegistersSeam < Minitest::Test
  LIB = File.expand_path("../../../lib", __dir__)

  # Where writing sound registers is somebody's job. The encoder's own file defines the thing,
  # and the GBA backend is the one that lowers to a cartridge.
  ALLOWED = [
    "lib/ruby_gba/audio/sound.rb",
    "lib/ruby_gba/ir/backends/gba/"
  ].freeze

  def test_only_the_gba_lowering_reads_the_sound_registers
    reaching = Hash.new { |h, k| h[k] = [] }

    Dir.glob(File.join(LIB, "**/*.rb")).sort.each do |path|
      short = path.delete_prefix("#{File.dirname(LIB)}/")
      next if ALLOWED.any? { |ok| short.start_with?(ok) }

      names_registers(path).each { |name| reaching[short] << name }
    end

    assert_empty reaching, <<~WHY
      These read the console's sound registers from outside the GBA lowering:

      #{reaching.map { |file, names| "  #{file}: #{names.uniq.join(', ')}" }.join("\n")}

      Registers turns a musical value into the exact half-words the hardware wants, so a
      backend that never writes hardware cannot want one. If what you need is a LIMIT of a
      voice — how many loudnesses it has, how low it goes — that belongs in the musical half
      of Sound, where both backends can read it. Move it there and read it from there.
    WHY
  end

  # A guard on the guard: the fact this test is looking for is a constant path, so it has to
  # find one when there really is one. Scanning the GBA backend's own audio file, which is
  # exempt above, must turn something up — otherwise a rename could make the check pass by
  # finding nothing anywhere.
  def test_the_check_can_see_a_reader
    audio = File.join(LIB, "ruby_gba/ir/backends/gba/audio.rb")

    refute_empty names_registers(audio), "the scan has stopped recognising a reader"
  end

  private

  # Every mention of Sound::Registers in the file's CODE — a comment that talks about it is
  # talking, not reaching.
  def names_registers(path)
    out = []
    stack = [Prism.parse_file(path).value]
    until stack.empty?
      node = stack.shift
      if node.is_a?(Prism::ConstantPathNode) && node.slice.include?("Sound::Registers")
        # The whole path, not its own leading pieces too — `A::Registers::THING` is one reach.
        out << node.slice
        next
      end
      stack.unshift(*node.compact_child_nodes)
    end
    out
  end
end

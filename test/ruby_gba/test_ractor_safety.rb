# frozen_string_literal: true

require "test_helper"

require "stringio"

# CAN A GAME CALL THIS LIBRARY FROM A RACTOR?
#
# A Ractor is Ruby's way of running two pieces of Ruby at the same time on two cores, which
# threads cannot do. The price is isolation: a worker may not reach anything mutable that
# another worker can also see. So a library is callable from one only if what it hands out is
# frozen ALL THE WAY DOWN — a frozen Hash of unfrozen Strings is still refused, and
# `Ractor.shareable?` is the only thing that answers the real question. `frozen?` does not.
#
# Why the library cares: a game that builds several cartridges at once — the Wolfenstein port
# does — wants to do it inside one process rather than forking one interpreter per build.
#
# THE RULE IS NARROWER THAN IT IS USUALLY QUOTED, and the difference decides what these tests
# ask. It is not "a worker cannot touch state kept on a class or module". A worker MAY read
# one. What it may not do is get an unshareable value out of one, or write one at all. So a
# table built while the file loads and frozen is legal to read from a worker and needs no
# redesign; only a mutable value, or a write that happens after the workers exist, is fatal.
#
# THESE ARE CENSUSES, NOT EXAMPLES. Each walks everything the library defines and names
# whatever is new, because this is drift: twenty-five unshareable constants on the day they
# were first counted, twenty-eight six days later. A test that froze three constants it knew
# about would have passed through both.
class TestRactorSafety < Minitest::Test
  # The program the two builds share. It lives in a module rather than in a test method
  # because a Ractor's block runs with a self of its own — a test's instance methods are
  # not reachable from inside one, but a constant is.
  module OneSmallGame
    module_function

    # A spread rather than a minimal program: a variable, a comparison, a fill, and text
    # (which reaches the font registry). Each was somewhere the library used to stop.
    def cartridge
      RubyGBA.build("RACTOR", out: StringIO.new, err: StringIO.new) do
        screen :bitmap
        clear_screen :blue
        x = var :x, 0
        game_loop do
          x.add! 1
          fill_rect 10, 10, 20, 20, :red
          draw_text "HELLO", :center, 100, :white
          (x >= 3).then { halt }
        end
      end.buffer
    end
  end

  # The one cache that cannot be made shareable, and the reason is not a tidy-up anybody has
  # been putting off. A declared game holds the author's own block so it can be built later,
  # and a block carries the surroundings it was written in — which is exactly the thing a
  # Ractor may not share. Declaring a game is a top-level act in a script, on the main Ractor,
  # so nothing is lost: what a worker does is BUILD a game, not declare one.
  KEPT_ON_THE_MAIN_RACTOR = [[RubyGBA, :@registered_games]].freeze

  def test_a_worker_can_read_every_constant_the_library_defines
    offenders = each_module.flat_map { |mod| unshareable_constants(mod) }

    assert_empty offenders, <<~WHY
      These constants hold something a worker Ractor cannot read:

      #{list(offenders)}

      Wrap the value in Ractor.make_shareable where it is defined. Not freeze: that stops at
      the outside, and a frozen Array of unfrozen Strings is still refused.
    WHY
  end

  # The other half of the same question. A lookup table built the first time something asks
  # for it is built by whoever asked first — and if that is a worker, it is a write to a
  # module from a worker, which Ruby refuses outright. Built while the file loads instead, it
  # is only ever read.
  #
  # WHAT THIS ONE CANNOT SEE is a lazy cache nothing has asked for yet: there is no value to
  # look at, so it reads as clean. That is why it is not the whole answer — the build below
  # is, since it runs the real thing and whatever it touches has to be reachable.
  def test_a_worker_can_read_every_cache_the_library_keeps_on_a_module
    offenders = each_module.flat_map { |mod| unshareable_module_state(mod) }

    assert_empty offenders, <<~WHY
      These caches hold something a worker Ractor cannot read:

      #{list(offenders)}

      Build the table while the file loads and freeze it, rather than the first time somebody
      asks for it. A worker that asks first would otherwise be writing to a module, which
      Ruby refuses whatever the value is.
    WHY
  end

  # THE ONE THAT ACTUALLY PROVES IT. The two censuses above are about what the library
  # holds; this one builds a whole cartridge inside a worker and compares it byte for byte
  # with the same build on the main Ractor. Anything still unreachable raises rather than
  # coming back wrong, so a failure here names the thing that stopped.
  def test_a_whole_cartridge_builds_inside_a_worker_and_comes_out_the_same
    on_main = OneSmallGame.cartridge
    in_worker = without_the_experimental_warning { Ractor.new { OneSmallGame.cartridge }.value }

    assert_equal on_main, in_worker,
                 "the same program built on two Ractors must produce the same cartridge"
  end

  # Ractors announce that they are experimental every time one is made. The library does
  # not choose that and a test run should not carry it.
  private def without_the_experimental_warning
    was = Warning[:experimental]
    Warning[:experimental] = false
    yield
  ensure
    Warning[:experimental] = was
  end

  private def each_module(mod = RubyGBA, seen = Set.new, found = [])
    return found unless mod.name&.start_with?("RubyGBA") && seen.add?(mod)

    found << mod
    mod.constants(false).each do |name|
      value = mod.const_get(name, false)
      each_module(value, seen, found) if value.is_a?(Module)
    end
    found
  end

  private def unshareable_constants(mod)
    mod.constants(false).filter_map do |name|
      value = mod.const_get(name, false)
      next if value.is_a?(Module) || Ractor.shareable?(value)

      ["#{mod.name}::#{name}", value.class]
    end
  end

  private def unshareable_module_state(mod)
    mod.instance_variables.filter_map do |name|
      next if KEPT_ON_THE_MAIN_RACTOR.include?([mod, name])

      value = mod.instance_variable_get(name)
      ["#{mod.name} #{name}", value.class] unless Ractor.shareable?(value)
    end
  end

  private def list(offenders) = offenders.map { |what, kind| "  #{what}  (#{kind})" }.join("\n")
end

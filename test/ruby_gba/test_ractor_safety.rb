# frozen_string_literal: true

require "test_helper"

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
# THIS IS A CENSUS, NOT AN EXAMPLE. The point is that it walks everything the library defines
# and names whatever is new, because this is drift: twenty-five constants on the day it was
# first counted, twenty-eight six days later. A test that froze three constants it knew about
# would have passed through both.
class TestRactorSafety < Minitest::Test
  def test_a_worker_can_read_every_constant_the_library_defines
    offenders = unshareable_constants(RubyGBA)

    assert_empty offenders, <<~WHY
      These constants hold something a worker Ractor cannot read:

      #{offenders.map { |name, kind| "  #{name}  (#{kind})" }.join("\n")}

      Wrap the value in Ractor.make_shareable where it is defined. Not freeze: that stops at
      the outside, and a frozen Array of unfrozen Strings is still refused.
    WHY
  end

  # Every constant under a module, its nested modules included, that a worker could not read.
  # Returns pairs of the full name and what kind of thing is in it, so a failure says enough
  # to go and fix it without looking anything up.
  private def unshareable_constants(root, seen = Set.new, found = [])
    return found unless seen.add?(root)

    root.constants(false).each do |name|
      value = root.const_get(name, false)

      if value.is_a?(Module)
        unshareable_constants(value, seen, found) if value.name&.start_with?("RubyGBA")
      elsif !Ractor.shareable?(value)
        found << ["#{root.name}::#{name}", value.class]
      end
    end

    found
  end
end

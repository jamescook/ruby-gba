# frozen_string_literal: true

require "test_helper"

require "stringio"
require "prism"

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

  # THE THREE A WORKER NEVER REACHES, each for its own reason and none of them a tidy-up
  # somebody has been putting off. Both censuses skip them; the build at the bottom does not,
  # so if a worker ever did reach one it would raise there rather than pass quietly.
  #
  #   @registered_games   a declared game keeps the author's own block so it can be built
  #                       later, and a block carries the surroundings it was written in —
  #                       which is the one thing a Ractor may never share. Declaring a game
  #                       is a top-level act in a script; what a worker does is build one.
  #   @save_dir           a real temporary directory. Making it as the library loads would
  #                       leave one behind for everybody who only ever builds cartridges,
  #                       and it is reached only through the emulator, which refuses a
  #                       worker outright.
  #   @default_adapter    finding the image tool on this machine costs a subprocess, so it
  #                       is put off until something actually reads a picture file.
  MAIN_RACTOR_ONLY = %i[@registered_games @save_dir @default_adapter].freeze

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
  # look at, so it reads as clean, and whether it reads as clean depends on which other tests
  # happened to share the process. The source check below is the one that always sees it.
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

  # The same question asked of the SOURCE rather than of the loaded library, which is the only
  # way to see a cache nothing has built yet.
  #
  # WHAT IT LOOKS FOR is `||=` on something kept by a class or module — which is exactly how
  # "work it out the first time somebody asks" is spelled, and is the shape that breaks. A
  # plain assignment in a method whose job is to change the registry is a different thing: a
  # game registering a font or a pack is configuring the library, which happens on the main
  # Ractor, and a worker only ever reads what it left. So this is narrow on purpose.
  #
  # It is parsed rather than searched for, because what decides it is whether the write
  # happens with a class or module as self — inside a `def self.x`, or under `class << self`.
  def test_the_library_never_works_a_cache_out_the_first_time_somebody_asks
    sources = Dir[File.expand_path("../../lib/**/*.rb", __dir__)].sort
    refute_empty sources, "the library should be where this test looks for it"
    offenders = sources.flat_map { |path| lazy_module_caches(path) }

    assert_empty offenders, <<~WHY
      These lines work something out the first time somebody asks and keep it on a class or
      module:

      #{list(offenders)}

      Whichever Ractor asked first would be the one writing it, and a worker may not write to
      a module at all, whatever the value. Build it while the file loads instead.
    WHY
  end

  # AND THE SAME QUESTION ASKED OF THE SUITE ITSELF, because a test file parks fixtures in
  # constants exactly the way the library does and gets them wrong the same way: the tile art
  # twenty-two files used to declare for themselves read `(("#" * 8) + "\\n").freeze * 8`,
  # where the freeze lands on the inner string and the multiplication then makes a fresh
  # unfrozen one. Nobody would spot that by looking.
  #
  # It runs in a process of its own, which is what makes it mean anything: a test can only
  # see the test classes loaded beside it, and under `rake test:parallel` that is one shard's
  # share of the suite. Asked from in here it would quietly cover a twelfth of what it claims
  # to. The script loads every test file instead, and costs about four tenths of a second.
  def test_a_worker_can_read_every_constant_the_suite_parks_in_a_test_class
    census = File.expand_path("../support/constant_census.rb", __dir__)
    found = IO.popen([RbConfig.ruby, census], &:read)

    assert_empty found.strip, <<~WHY
      These test constants hold something a worker Ractor cannot read:

      #{found}
      Nearly always this is already handled: test_helper freezes whatever a test class parks
      in a constant, the moment it is declared. Something here refused — almost certainly a
      block that reaches for a variable around it, which can never be shared. Build it in a
      method instead, so each worker makes its own. A fixture several files want belongs in
      SharedConstants in test/test_helper.rb.
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
      next if MAIN_RACTOR_ONLY.include?(name)

      value = mod.instance_variable_get(name)
      ["#{mod.name} #{name}", value.class] unless Ractor.shareable?(value)
    end
  end

  private def lazy_module_caches(path)
    finder = LazyModuleCaches.new(path.delete_prefix("#{File.expand_path('../..', __dir__)}/"))
    Prism.parse_file(path).value.accept(finder)
    finder.found.reject { |_where, name| MAIN_RACTOR_ONLY.include?(name) }
  end

  private def list(offenders) = offenders.map { |what, kind| "  #{what}  (#{kind})" }.join("\n")

  # Somewhere a class or module works a value out the first time it is asked for and keeps it.
  class LazyModuleCaches < Prism::Visitor
    attr_reader :found

    def initialize(path)
      super()
      @path = path
      @found = []
      @singleton = 0 # how deep inside `def self.x` / `class << self` we are
      @module_function = false
    end

    def visit_def_node(node)
      was = @singleton
      @singleton += 1 if node.receiver || @module_function
      super
      @singleton = was
    end

    def visit_singleton_class_node(node)
      @singleton += 1
      super
      @singleton -= 1
    end

    # `module_function` and `extend self` turn the plain `def`s that follow them into
    # methods on the module, so those count too. Each applies to one module body, so the
    # flag is put back on the way out of a nested one.
    def visit_call_node(node)
      @module_function = true if module_level_from_here?(node)
      super
    end

    def visit_module_node(node) = in_a_fresh_body { super }
    def visit_class_node(node) = in_a_fresh_body { super }

    private def in_a_fresh_body
      was = @module_function
      @module_function = false
      yield
      @module_function = was
      nil
    end

    private def module_level_from_here?(node)
      return true if node.name == :module_function && node.arguments.nil?

      node.name == :extend && node.arguments&.arguments&.first.is_a?(Prism::SelfNode)
    end

    def visit_instance_variable_or_write_node(node) = record(node)
    def visit_instance_variable_operator_write_node(node) = record(node)

    private def record(node)
      @found << ["#{@path}:#{node.location.start_line}", node.name] if @singleton.positive?
      nil
    end
  end
end

# frozen_string_literal: true

require "etc"
require "rake"
require "rake/testtask"
require_relative "lowering"

module VBlank
  module Testing
    # ONE TEST TASK, FOR ONE LOWERING, under a name and over files the game chooses — for a game
    # whose Rakefile keeps its own rake test and a task for each group of its tests, and wants a
    # native twin of a group without the rest of RakeTasks:
    #
    #   require "vblank/testing/test_task"
    #
    #   namespace :test do
    #     namespace :native do
    #       VBlank::Testing::TestTask.new(:items) do |t|
    #         t.lowering = :native
    #         t.libs = %w[games/minish_cap/lib test]
    #         t.test_files = FileList["test/items/**/test_*.rb"]
    #       end
    #     end
    #   end
    #
    # It is rake's own test task (everything Rake::TestTask takes, it takes), told which lowering
    # its run is for. RakeTasks makes its two runs out of two of these, so a twin a game makes is
    # the run `rake test:lowering:native` is, and how a native run is started lives here alone.
    #
    # A NATIVE RUN is played differently, and this is all of how. Every test starts zig and the
    # program it builds, which Ruby cannot do from inside a Ractor, so it is plain minitest's
    # whatever the game says about Ractors (no --ractor, no MT_RACTOR); its tests are spread over
    # several processes instead (Processes) — TEST_PROCESSES of them, or as many as the Ractor run
    # has workers, or half the machine's cores — each playing one test at a time (MT_CPU=1). And
    # zig is asked for before any test is played, so a missing or wrong one stops the run with
    # one plain line rather than failing every test in turn.
    #
    # A JAVASCRIPT RUN is played the same way, for the same reason — every test starts node and
    # the program it builds — and asks for node in place of zig.
    #
    # None of that is written into the settings of the rake process: it is handed to the run this
    # task starts and to nothing else, so a GBA run after it in the same rake call is played as the
    # game set it up.
    #
    # The name is required, since rake's own test task left without one is `rake test` — the
    # one task a game that keeps its own was making this to stay clear of.
    class TestTask < Rake::TestTask
      # The lowering this task's run is for, :gba unless told.
      attr_reader :lowering

      def initialize(name)
        @lowering = :gba
        super
      end

      # Said inside the block, where the task is being made: a native run is made with the
      # process runner loaded, which is settled as the task is defined.
      def lowering=(lowering)
        refuse_lowering_after_definition!
        unless Lowering::NAMES.include?(lowering)
          raise ArgumentError, "This test task was given #{lowering.inspect} as its lowering. " \
                               "Give it #{Lowering.in_words(Lowering::NAMES.map(&:inspect))}."
        end

        @lowering = lowering
      end

      def define
        @ruby_opts << "-r#{File.expand_path('processes.rb', __dir__)}" if checked?
        @defined = true
        super
      end

      # The test options this run is played with. A native or JavaScript run leaves out --ractor.
      def option_list(...)
        checked? ? without_ractor(super) : super
      end

      private

      # Rake's test task plays its run through here, so this is where the run is handed what
      # it is for: the lowering, and on a native run the rest of how it is played. The program the
      # run needs (Lowering::Run#needs) is asked for first.
      def ruby(*args, **options, &block)
        needs = Lowering.run_named(lowering).needs
        refuse_native_run_without_zig! if needs == "zig"
        refuse_js_run_without_node! if needs == "node"
        sh(run_settings, [FileUtils::RUBY, *yjit_switch, *args].join(" "), **options, &block)
      end

      def checked? = Lowering.run_named(lowering).checked?

      # A run whose tests are played in Ractors: one that is not checked, told --ractor.
      def in_ractors? = !checked? && option_list.split.include?("--ractor")

      # Is the run played with YJIT, Ruby's compiler of hot methods to machine code? Where its
      # record says YJIT makes it faster (Lowering::Run#yjit), and never in Ractors: with several
      # running at once it makes a run many times slower. Off is said on Ruby's command line,
      # which wins over a --yjit in RUBYOPT; on is said in the environment (#run_settings), which
      # the processes a checked run starts for its tests inherit. A Ruby built without YJIT takes
      # both and ignores them.
      def yjit? = Lowering.run_named(lowering).yjit? && !in_ractors?

      def yjit_switch = yjit? ? [] : ["--disable-yjit"]

      def without_ractor(options) = (options.split - %w[--ractor]).join(" ")

      # What the run is handed. A native or JavaScript run's own copy of TESTOPTS loses --ractor
      # too, since a test that starts a run of its own hands that copy on. YJIT as #yjit? says.
      def run_settings
        yjit = { "RUBY_YJIT_ENABLE" => yjit? ? "1" : nil }
        return { Lowering::SETTING => "gba", **yjit } unless checked?

        { Lowering::SETTING => lowering.to_s, "MT_RACTOR" => nil, "MT_CPU" => "1", **yjit,
          "TESTOPTS" => ENV["TESTOPTS"] && without_ractor(ENV["TESTOPTS"]),
          "TEST_PROCESSES" => ENV.fetch("TEST_PROCESSES") { ENV.fetch("MT_RACTOR_WORKERS") { [Etc.nprocessors / 2, 1].max.to_s } } }
      end

      def refuse_lowering_after_definition!
        return unless @defined

        raise ArgumentError, "This test task is already made, so its lowering cannot change. " \
                             "Say the lowering inside the block that makes it."
      end

      def refuse_native_run_without_zig!
        require_relative "../root"
        require_relative "../ir/backends/native/zig"
        IR::Backends::Native::Zig.version
      rescue IR::Backends::Native::Zig::Error => e
        abort "The native lowering's run needs zig, and #{e.message}"
      end

      def refuse_js_run_without_node!
        require_relative "../ir/backends/js/node"
        IR::Backends::JS::Node.version
      rescue IR::Backends::JS::Node::Error => e
        abort "The JavaScript lowering's run needs node, and #{e.message}"
      end
    end
  end
end

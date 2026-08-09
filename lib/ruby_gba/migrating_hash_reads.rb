# frozen_string_literal: true

module RubyGBA
  # Scaffolding for turning a bare Hash into a value object without one enormous edit.
  #
  # A value object that includes this still answers hash-style reads, so the moment a
  # structure changes type every existing call site keeps working. Each site is recorded
  # the first time it runs — file, line, and the field it asked for — and the collected
  # list is what says where the remaining work is. Run the suite, read the list, move
  # those sites to real readers, run it again. The list shrinks to nothing and then this
  # module comes out of the class.
  #
  # That is the whole point: the sites are produced by running the code, not by grepping
  # for a pattern that a multi-line expression or an unusual receiver name would hide.
  #
  # A read of something that is not a field of the object raises, which is the behavior
  # being migrated TO — a hash answered nil and let a typo through. Ask #key? when the
  # question is genuinely whether a field exists.
  module MigratingHashReads
    SITES = {}

    module_function

    # Every place that still reads one of these objects hash-style: "file:line" mapped to
    # the class and the field it wanted. Sorted, so two runs give the same list.
    def sites
      SITES.sort.to_h
    end

    def record(site, owner, key)
      SITES["#{site.path}:#{site.lineno}"] ||= "#{owner} [#{key.inspect}]"
    end

    # Printed when RUBY_GBA_MIGRATION is set, so a normal build stays quiet and a deliberate
    # run gets the list. Called from more than one place — a plain script exits through
    # at_exit, a test run through the test framework's own end-of-run hook — so it prints the
    # once however it is reached.
    def report(out = $stderr)
      return if SITES.empty? || @reported

      @reported = true
      out.puts "\nstill reading a value object like a hash (#{SITES.size} sites):"
      sites.each { |where, what| out.puts "  #{where}  #{what}" }
    end

    # Mixed into the value object itself. Hash-style reading is not only #[] — a caller that
    # copies with a change says #merge and one that reaches through says #dig, and both are
    # sites to move as much as a bracket is. They record too, or a conversion would look
    # finished while a #merge sat waiting to fail.
    module Reads
      def [](key)
        record_site(caller_locations(1, 1).first, key)
        public_send(key)
      end

      def merge(changes)
        record_site(caller_locations(1, 1).first, :merge)
        with(**changes)
      end

      def dig(key, *rest)
        record_site(caller_locations(1, 1).first, key)
        value = public_send(key)
        rest.empty? ? value : value&.dig(*rest)
      end

      # The escape hatch: asking whether a field exists at all, which a caller cannot do
      # with #[] now that an unknown field raises.
      def key?(key)
        self.class.members.include?(key)
      end

      private

      def record_site(site, key)
        MigratingHashReads.record(site, self.class.name, key)
      end
    end
  end
end

at_exit { RubyGBA::MigratingHashReads.report } if ENV["RUBY_GBA_MIGRATION"]

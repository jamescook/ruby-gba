# frozen_string_literal: true

module RubyGBA
  # Manages a raw GBA ROM byte buffer and writes the cartridge header.
  #
  # All offsets reference constants from {RubyGBA::Constants} — no magic
  # numbers in the logic. This makes it easy to sanity-check header writes
  # and catch offset mistakes early.
  #
  # Reference: https://problemkaputt.de/gbatek-gba-cartridge-header.htm
  class ROM
    include Constants

    HEADER_SIZE  = 0xC0
    ENTRY_OFFSET = HEADER_SIZE  # code starts after the full header
    TITLE_LENGTH = 12
    CODE_LENGTH  = 4
    MAKER_LENGTH = 2
    FIXED_VALUE  = 0x96
    CHECKSUM_RANGE = (HEADER_TITLE..0xBC).freeze

    attr_reader :buffer, :code_offset

    # WHAT THE BUILD WORKED OUT about this cartridge, or nil when nothing did (see
    # {BuildRecord}). It arrives whole, at construction, so a ROM is either a cartridge
    # that can report on itself or a cartridge that cannot — never half of each. Nil is
    # what "assembled straight from machine code" looks like.
    attr_reader :built

    # The things the record holds, read straight off it. Each is nil without a record,
    # and each is documented on {BuildRecord}: the IR program this cartridge was built from,
    # which routines it keeps in the console's quick memory, where its variables landed,
    # which shape each of its loops got, how many colors each screen draws through, which
    # see-through pictures skip the rows they have nothing in, what each node of the program
    # turned into, how far asset packing shrank it, and the options it was built with.
    def source_program = @built&.source_program
    def emitted = @built&.emitted
    def placement = @built&.placement
    def var_addresses = @built&.var_addresses
    def loop_shapes = @built&.loop_shapes
    def palette_entries = @built&.palette_entries
    def column_stretches = @built&.column_stretches
    def compression = @built&.compression
    def build_options = @built&.build_options

    # Package finished machine code into a cartridge: write the header, drop the
    # code in after it, and finalize (entry branch, checksum, power-of-two
    # padding, and the ROM-image validation). This is the counterpart to a
    # backend's lowering — the backend produces the code, this lays out the ROM
    # around it.
    #
    # +built+ is what the build worked out on the way here, which is what lets the finished
    # cartridge report on itself. A caller with a backend to hand gets it in one call —
    # `built: backend.build_record(program)`. Leave it out and the ROM is a cartridge and
    # nothing more, which is right for machine code that came from somewhere else.
    def self.assemble(machine_code, title:, code:, maker:, validate: true, built: nil)
      rom = new(title: title, code: code, maker: maker, built: built)
      rom.emit(machine_code)
      rom.finalize!(validate: validate)
      rom
    end

    def initialize(title:, code:, maker:, built: nil)
      @built = built
      @buffer = ("\x00".b) * [512, HEADER_SIZE].max
      @code_offset = ENTRY_OFFSET

      write_logo
      write_title(title)
      write_code(code)
      write_maker(maker)
      @buffer.setbyte(HEADER_FIXED, FIXED_VALUE)
    end

    # Append raw bytes at the current code offset and advance.
    def emit(bytes)
      grow_if_needed(@code_offset + bytes.bytesize)
      @buffer[@code_offset, bytes.bytesize] = bytes
      @code_offset += bytes.bytesize
    end

    # Overwrite bytes at a specific offset (for patching branch placeholders).
    def patch(offset, bytes)
      @buffer[offset, bytes.bytesize] = bytes
    end

    # Finalize the ROM: write entry branch, header checksum, and validate.
    #
    # @param validate [Boolean] run the ROM-image validation (structural header /
    #   image checks) after finalizing (default: true). Raises ROMError on a
    #   structural problem. Pass false to skip.
    def finalize!(validate: true)
      # Entry point at 0x00: branch to ENTRY_OFFSET
      # Branch offset in words from PC+8: (target - 8) / 4 = (0x20 - 8) / 4 = 6
      entry_branch = [0xEA000000 | ((ENTRY_OFFSET / 4) - 2)].pack("V")
      @buffer[HEADER_ENTRY, 4] = entry_branch

      # Complement checksum over HEADER_TITLE..0xBC
      sum = CHECKSUM_RANGE.sum { |i| @buffer.getbyte(i) }
      @buffer.setbyte(HEADER_CHECKSUM, (-(sum + 0x19)) & 0xFF)

      # Real GBA cartridges are power-of-two sized. Pad up to the next one with
      # zeros — it's past the checksum range, so this is free, and it keeps the
      # ROM conventional for flashcarts and real-cart mastering.
      pad_to_power_of_two

      # Validate the finished ROM image — catch structural problems now, not in
      # the emulator. (Semantic footguns are caught earlier, on the IR, by the
      # guardrails.)
      if validate
        result = ROMValidator.check(self)
        unless result.ok?
          raise ROMError, "ROM has errors:\n#{result.report}"
        end
      end
    end

    # Print the per-frame cost report for this ROM to +out+: where each frame's work goes
    # (or the one-time boot cost, if it never loops), and whether it fits the frame and the
    # brief window the console has to change the screen without tearing (see
    # {IR::CostModel}).
    #
    # +measured+ decides what the VERDICT rests on. The breakdown is always the estimate —
    # it is the only thing that can say where a frame goes, statement by statement. Whether
    # the frame FITS is a different question, and the estimate can only guess at it: it
    # cannot see a loop counted at run time, or a stall while the console's own copier works.
    # `measured: true` runs the cartridge on the emulator and reads the real frame, scene by
    # scene, so the verdict is a measurement and the report says so. A Hash is a reading
    # somebody else took, in the shape {Analyzer::Result#for_report} gives. Left out, the
    # verdict is the estimate's own, and the report says how to ask for the real one.
    # +scenes+ narrows the measuring to the named scenes and +keys+ pins which buttons are
    # held while it runs; both need `measured: true`.
    #
    # Measuring needs the emulator (gemba-core). A build with no emulator still gets an
    # answer rather than an error: the estimate, and a line saying what the measured one
    # needs.
    #
    # +format+ selects the view: :human is the drill-down tree (accepts max_depth:,
    # focus:, top: to scope it), :summary is the one-line verdict, and :json is the
    # structured cost tree for tools and tests to consume without parsing text.
    #
    # The human/summary views print a colour heatmap — each cost line tinted by how much
    # of the frame budget it uses, file subtotals in bold — when the output is a terminal.
    # Pass color: false to force plain text (or false-y auto-off happens for a pipe or a
    # captured StringIO, and whenever NO_COLOR is set).
    def explain(format: :human, out: $stdout, measured: nil, scenes: nil, keys: nil, **opts)
      program = built!.source_program
      model = cost_model
      readings, unmeasured = measurement(measured, scenes: scenes, keys: keys)
      case format
      when :human   then model.render(program, out: out, measured: readings, unmeasured: unmeasured, **opts)
      when :summary then model.report(program, out: out, measured: readings, unmeasured: unmeasured, **opts)
      when :json
        json = model.as_json(program, measured: readings, unmeasured: unmeasured).merge(findings: findings_json)
        out.puts(JSON.generate(json))
      else raise ArgumentError, "unknown explain format #{format.inspect} (use :human, :summary, or :json)"
      end
    end

    # WHERE THIS GAME'S FRAMES ACTUALLY WENT — measured by running it, not worked out.
    #
    # `explain` reads the program and says what it thinks a frame will cost. This runs the
    # cartridge and says what it did cost, routine by routine, with the frame rate the console
    # really produced and how much of each frame was left over. Nothing here is predicted, so
    # nothing here can be wrong about a loop it could not see through.
    #
    # +scene+ names which screen to measure, and it is usually the thing you want: a game boots
    # to its title, and holding a button will not get past one — a menu reads the press EDGE, so
    # a held button is one press however long it is held. Naming a scene holds the game there
    # and measures that, with nobody having to play it (see {Profiler.pinned_to}).
    #
    # +keys+ are held throughout, and it is worth passing them: a game costs what the player
    # makes it cost, and a profile with nothing held is a profile of a game standing still.
    # +settle+ runs that many frames first, and +frames+ is how many to measure over.
    #
    # +format+ is :human to print it or :json for the same numbers as data.
    #
    # Needs the emulator (gemba-core) and a cartridge that knows how it was built — the
    # addresses each routine runs at cannot be recovered from the bytes, because a routine kept
    # in the console's quick memory was copied there at boot.
    def profile(format: :human, out: $stdout, frames: Profiler::FRAMES,
                settle: Profiler::SETTLE, keys: [], scene: nil)
      built! # a cartridge with no record cannot name its own routines
      result = Profiler.run(self, frames: frames, settle: settle, keys: keys, scene: scene)
      case format
      when :human then Profiler.render(result, out: out)
      when :json  then out.puts(JSON.generate(result.to_h))
      else raise ArgumentError, "unknown profile format #{format.inspect} (use :human or :json)"
      end
      result
    end

    # What the guardrails said about this cartridge, as data: the check, how serious it was,
    # the message, and the author's line it points at.
    def findings_json
      built!.findings.map do |finding|
        { check: finding.check, severity: finding.severity, message: finding.message, at: finding.source }
      end
    end

    # A cost model that knows how THIS ROM was built. The estimate has to know which
    # routines the build kept in the console's quick memory, or it reads nearly three
    # times over for every program whose loop moved there (see {IR::CostModel#initialize}).
    # So a model asked about a built ROM comes from here rather than from CostModel.new.
    # +overrides+ replaces named weights, for asking what a different price would mean.
    #
    # A cartridge with no record REFUSES rather than falling back on defaults. Every one of
    # those defaults is the safe, dearer guess — a loop priced through memory, a variable
    # priced as if it sat far out — so an estimate built on them reads plausibly and is
    # wrong by nearly the factor the quick memory is worth, with nothing on the page to say
    # so. A number nobody can tell is wrong is worse than no number.
    def cost_model(**overrides)
      IR::CostModel.new(**built!.for_cost_model, **overrides)
    end

    # Write the ROM to a file.
    def write(path)
      File.binwrite(path, @buffer)
    end

    # ROM size in bytes.
    def size
      @buffer.bytesize
    end

    private

    # The readings the verdict rests on, and when there are none, why not: [readings, reason].
    # The reason is what the report's "estimate only" line turns on — not asked for and
    # asked for with nothing to run it on want different advice.
    def measurement(asked, scenes:, keys:)
      if (scenes || keys) && asked != true
        raise ArgumentError, "scenes: and keys: say how to measure the game. Pass measured: true with them."
      end

      case asked
      when true then measure(scenes: scenes, keys: keys)
      when Hash then [asked, nil]
      when nil, false then [nil, :not_asked]
      else
        raise ArgumentError, "measured: takes true (run the game on the emulator), a Hash of readings, " \
                             "or nothing. It does not take #{asked.inspect}."
      end
    end

    # Run this cartridge's program on the emulator and hand back the readings the report
    # folds in. The profiler builds its own measuring ROMs from the program — a scene is
    # measured by booting straight into it, and an over-budget frame by counting the game
    # loop's passes — so what it needs is the program and the options it was built with,
    # not these bytes. Without the emulator there is nothing to run, and that is the reason
    # handed back.
    def measure(scenes:, keys:)
      readings = Analyzer.profile(built!.source_program, options: built!.build_options,
                                                         only: scenes, keys: keys)
      [readings.transform_values(&:for_report), nil]
    rescue LoadError
      [nil, :no_emulator]
    end

    # What the build worked out, for the two callers that cannot do their job without it.
    def built!
      @built || raise(ROMError,
                      "This cartridge does not know how it was built, so it cannot report on itself. " \
                      "Build it with `RubyGBA.build` and the record comes with it.")
    end

    # The GBA BIOS validates the 156-byte Nintendo logo at 0x04..0x9F on boot.
    # It sits outside the header checksum range (0xA0..0xBC), so writing it here
    # doesn't affect the checksum computed in finalize!.
    def write_logo
      @buffer[HEADER_LOGO, HEADER_LOGO_BYTES.bytesize] = HEADER_LOGO_BYTES
    end

    def write_title(title)
      padded = title[0, TITLE_LENGTH].ljust(TITLE_LENGTH, "\x00")
      @buffer[HEADER_TITLE, TITLE_LENGTH] = padded
    end

    def write_code(code)
      raise ArgumentError, "game code must be #{CODE_LENGTH} chars" unless code.bytesize == CODE_LENGTH
      @buffer[HEADER_CODE, CODE_LENGTH] = code
    end

    def write_maker(maker)
      raise ArgumentError, "maker code must be #{MAKER_LENGTH} chars" unless maker.bytesize == MAKER_LENGTH
      @buffer[HEADER_MAKER, MAKER_LENGTH] = maker
    end

    def grow_if_needed(min_size)
      return if @buffer.bytesize >= min_size
      new_size = [@buffer.bytesize * 2, min_size].max
      @buffer << ("\x00".b) * (new_size - @buffer.bytesize)
    end

    def pad_to_power_of_two
      target = next_power_of_two(@buffer.bytesize)
      @buffer << ("\x00".b) * (target - @buffer.bytesize) if target > @buffer.bytesize
    end

    # The smallest power of two >= n (found by shifting, so no float rounding).
    def next_power_of_two(n)
      power = 1
      power <<= 1 while power < n
      power
    end
  end
end

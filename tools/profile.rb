# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "rbconfig"

# `rake profile` — did that change to the compiler cost anything?
#
# Three times now the question was answered by hand: check out an old copy of the
# library, write a throwaway script that lowers a program and prints its size, run
# it against both copies, squint. This is that, with the squinting removed.
#
#   rake profile              the working tree against HEAD, every example
#   rake profile REF=HEAD~3   against some other point in history
#   rake profile ONLY=pong    one example (or a few: ONLY=pong,snake)
#
# It compares two versions of the LIBRARY, so it only means anything while working
# on ruby-gba itself — hence a contributor's rake task and not part of the
# `ruby-gba` command a game author runs.
#
# Every example, by default, because the question has never really been "what does
# this one game cost". It is "did anything move anywhere", and twenty-five real
# programs answer that far better than one.
#
# WHAT IT REPORTS, and why it is three numbers and not one:
#
#   code   the emitted instructions. What a change to the lowering moves.
#   data   the embedded assets — tile pictures, maps, sound samples. A new sprite
#          sheet is twenty kilobytes and not one extra instruction, so a single
#          total that mixed the two would say nothing.
#   frame  the estimated work in one frame, in scanlines. Size and speed move
#          independently: making a clamp accept a computed bound added thirty
#          instructions of ROM and nothing at all per frame.
module Profile
  ROOT = File.expand_path("..", __dir__)
  PROBE = File.join(__dir__, "profile_probe.rb")
  EXAMPLES = File.join(ROOT, "examples")

  # Every ARM instruction the backend emits is four bytes, so code is reported in
  # instructions — the unit the change was thought about in.
  BYTES_PER_INSTRUCTION = 4

  # Below these, a row is counted but not printed. A run where twenty-four
  # examples are untouched and one moved by a byte should read as "nothing
  # happened", not as a table. Nothing is dropped silently: whatever falls under
  # the floor is still named on the tally line.
  QUIET_CODE = BYTES_PER_INSTRUCTION # one instruction
  QUIET_DATA = 4                     # one alignment pad
  QUIET_FRAME = 0.05                 # a twentieth of a scanline

  # What one example emitted when built against one version of the library.
  # +error+ is set instead of the numbers when it would not build at all — being
  # unbuildable on one side is a result, not a crash.
  Measurement = Data.define(:name, :title, :code, :data, :frame, :error) do
    def ok? = error.nil?
  end

  # One example, measured on both sides.
  Row = Data.define(:name, :before, :after) do
    def paired? = before&.ok? && after&.ok?

    def code_delta = paired? ? after.code - before.code : 0
    def data_delta = paired? ? after.data - before.data : 0

    def frame_delta
      return 0.0 unless paired? && before.frame && after.frame

      after.frame - before.frame
    end

    def state
      return :broken if before&.ok? && !after&.ok?
      return :new if after&.ok? && !before&.ok?
      return :failing unless paired?
      return :same if code_delta.zero? && data_delta.zero? && frame_delta.abs < 1e-9

      moved? ? :changed : :quiet
    end

    # Did it move by enough to be worth a row?
    def moved?
      code_delta.abs > QUIET_CODE || data_delta.abs > QUIET_DATA || frame_delta.abs > QUIET_FRAME
    end

    # Rank by how far something moved, not by how big it is — a hundred-instruction
    # jump in the smallest example is the interesting one.
    def rank = [-code_delta.abs, -data_delta.abs, -frame_delta.abs]
  end

  module_function

  # ------------------------------------------------------------------
  # Driving
  # ------------------------------------------------------------------

  def run(ref: "HEAD", only: nil, out: $stdout)
    paths = examples(only)
    abort "No examples matched ONLY=#{only}." if paths.empty?

    commit = resolve(ref)
    out.puts "Building #{paths.size} #{paths.size == 1 ? 'example' : 'examples'} " \
             "against the working tree and against #{ref}, #{subject(commit)}."
    out.puts

    after = measure(File.join(ROOT, "lib"), paths)
    before = with_lib_at(commit) { |lib_root| measure(lib_root, paths) }

    Report.new(rows(paths, before, after), ref: "#{ref} (#{commit[0, 7]})").render(out)
  end

  # The example programs, as absolute paths. A game file is one that declares a
  # game; anything else under examples/ (a part of a multi-file example, a helper)
  # is reached by the file that uses it.
  def examples(only = nil)
    wanted = only.to_s.split(",").map { |name| name.strip.sub(/\.rb\z/, "") }.reject(&:empty?)
    paths = Dir[File.join(EXAMPLES, "*.rb")].sort.select { |path| File.read(path).include?("RubyGBA.game") }
    return paths if wanted.empty?

    paths.select { |path| wanted.include?(File.basename(path, ".rb")) }
  end

  # Build every example against the library at +lib_root+, one process each.
  def measure(lib_root, paths)
    paths.to_h { |path| [File.basename(path, ".rb"), probe(lib_root, path)] }
  end

  def probe(lib_root, path)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, PROBE, lib_root, ROOT, path, chdir: ROOT)
    measurement(File.basename(path, ".rb"), stdout, stderr, status)
  end

  # What the child process said, as a Measurement.
  def measurement(name, stdout, stderr = nil, status = nil)
    report = JSON.parse(stdout.to_s.lines.last.to_s, symbolize_names: true)
    raise JSON::ParserError, "no report" unless report.is_a?(Hash)

    Measurement.new(name: name, title: report[:title], code: report[:code],
                    data: report[:data], frame: report[:frame], error: report[:error])
  rescue JSON::ParserError, TypeError
    Measurement.new(name: name, title: nil, code: nil, data: nil, frame: nil,
                    error: last_words(stderr, status))
  end

  # A probe that died before it could report says nothing on stdout, so whatever
  # it managed to say on the way out is the diagnosis. Being unbuildable is a
  # result to report, not a reason to stop the run.
  def last_words(stderr, status)
    said = stderr.to_s.lines.last&.strip
    return said unless said.nil? || said.empty?

    status ? "the build died (exit #{status.exitstatus})" : "the build said nothing"
  end

  def rows(paths, before, after)
    paths.map do |path|
      name = File.basename(path, ".rb")
      Row.new(name: name, before: before[name], after: after[name])
    end
  end

  # ------------------------------------------------------------------
  # The other version of the library
  # ------------------------------------------------------------------

  # Lay the library as it was at +commit+ into a temporary directory and hand back
  # its path. Only lib/ is taken — the examples stay as they are in the working
  # tree, which is the point: a checkout would bring that commit's examples along
  # too, and then an edited game would score as a compiler change.
  def with_lib_at(commit)
    Dir.mktmpdir("ruby-gba-profile") do |dir|
      statuses = Open3.pipeline(["git", "-C", ROOT, "archive", commit, "lib"], ["tar", "-x", "-C", dir])
      abort "Could not read lib/ at #{commit}." unless statuses.all?(&:success?)

      yield File.join(dir, "lib")
    end
  end

  def resolve(ref)
    sha, status = Open3.capture2("git", "-C", ROOT, "rev-parse", "--verify", "#{ref}^{commit}")
    abort "#{ref} is not a commit in this repository." unless status.success?

    sha.strip
  end

  def subject(commit)
    line, status = Open3.capture2("git", "-C", ROOT, "log", "-1", "--format=%h %s", commit)
    status.success? ? line.strip : commit[0, 7]
  end

  # ------------------------------------------------------------------
  # Reporting
  # ------------------------------------------------------------------

  # Turns the paired measurements into the table and the one line worth keeping.
  class Report
    LABEL = {
      new: "new — only builds on the working tree",
      failing: "does not build on either side",
    }.freeze

    def initialize(rows, ref: "HEAD")
      @rows = rows
      @ref = ref
    end

    def render(out)
      broken.each do |row|
        out.puts "  #{row.name}: BROKEN — it builds at #{@ref} and does not build now."
        out.puts "    #{row.after.error}"
      end
      out.puts if broken.any?

      table(out)
      tally(out)
      out.puts
      out.puts summary
    end

    # The pasteable line — the one that ends up in a commit message, which is what
    # was being written by hand before.
    def summary
      return "#{count} vs #{@ref}: nothing to compare." if @rows.empty?

      body =
        if quiet_run? then "identical — no change in code, data or frame work"
        else [code_summary, data_summary, frame_summary].compact.join(", ")
        end
      "#{count} vs #{@ref}: #{[regression, body].compact.join('; ')}."
    end

    # A program that used to build and now does not outranks any measurement, so
    # it leads the line rather than sitting in a table above it.
    def regression
      return nil if broken.empty?

      "#{broken.size} NO LONGER BUILDS (#{broken.map(&:name).join(', ')})"
    end

    private

    def broken = @rows.select { |row| row.state == :broken }
    def notable = @rows.select { |row| %i[changed new failing].include?(row.state) }
    def paired = @rows.select(&:paired?)

    def quiet_run?
      broken.empty? && notable.empty? && @rows.none? { |row| row.state == :quiet }
    end

    def count = "#{@rows.size} #{@rows.size == 1 ? 'example' : 'examples'}"

    def table(out)
      return if notable.empty?

      width = notable.map { |row| row.name.length }.max
      out.puts format("  %-#{width}s  %14s  %12s  %12s", "example", "code (instr)", "data", "frame")
      notable.sort_by(&:rank).each do |row|
        if row.state == :changed
          out.puts format("  %-#{width}s  %14s  %12s  %12s", row.name,
                          code_cell(row), data_cell(row), frame_cell(row))
        else
          out.puts format("  %-#{width}s  %s", row.name, LABEL.fetch(row.state))
        end
      end
      out.puts
    end

    # Everything the table left out, so a quiet run still accounts for every
    # example rather than just showing less.
    def tally(out)
      same = @rows.count { |row| row.state == :same }
      quiet = @rows.select { |row| row.state == :quiet }
      parts = []
      parts << "#{same} unchanged" if same.positive?
      parts << "#{quiet.size} moved less than the noise floor (#{quiet.map(&:name).join(', ')})" if quiet.any?
      out.puts "  #{parts.join('. ')}." if parts.any?
    end

    def code_cell(row)
      percent = row.before.code.positive? ? format(" %+.1f%%", (row.code_delta * 100.0) / row.before.code) : ""
      "#{instructions(row.code_delta)}#{percent}"
    end

    def data_cell(row) = row.data_delta.zero? ? "—" : format("%+d B", row.data_delta)
    def frame_cell(row) = row.frame_delta.abs < 1e-9 ? "—" : format("%+.1f", row.frame_delta)

    # Code in instructions, since that is the unit a lowering change is thought
    # about in. Bytes only for the odd size the escape hatch can emit, which is
    # never a whole number of instructions.
    def instructions(bytes)
      return "—" if bytes.zero?
      return format("%+d B", bytes) unless (bytes % BYTES_PER_INSTRUCTION).zero?

      format("%+d", bytes / BYTES_PER_INSTRUCTION)
    end

    def total(field) = paired.sum { |row| row.public_send(field) }

    def code_summary
      delta = total(:code_delta)
      base = paired.sum { |row| row.before.code }
      return "code unchanged" if delta.zero?

      percent = base.positive? ? format(" (%+.2f%%)", (delta * 100.0) / base) : ""
      unit = delta.abs == BYTES_PER_INSTRUCTION ? "instruction" : "instructions"
      "code #{instructions(delta)} #{unit}#{percent}"
    end

    def data_summary
      delta = total(:data_delta)
      delta.zero? ? "data unchanged" : format("data %+d bytes", delta)
    end

    # One number can't sum frame work — the examples don't share a frame — so
    # report the biggest single move and where it happened.
    def frame_summary
      worst = paired.max_by { |row| row.frame_delta.abs }
      return "frame work unchanged" if worst.nil? || worst.frame_delta.abs < 1e-9

      format("frame work %+.1f scanlines at worst (%s)", worst.frame_delta, worst.name)
    end
  end
end

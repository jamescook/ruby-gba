# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "tmpdir"

module RubyGBA
  module IR
    module Backends
      class Native
        # Turns C into a program the computer can run, with zig as the C compiler.
        #
        # zig carries clang and a C library of its own for every platform it targets, which is
        # why this backend uses it rather than whatever compiler the machine happens to have:
        # the same zig builds the same program on a Mac, on Linux, and for Windows from either.
        #
        # A compile takes about a second, so the result is kept and handed back the next time
        # the same C is asked for with the same settings. The key is a hash of everything that
        # can change the program — every source, every header in the runtime, every flag, and
        # zig's own version — so a stale program can never be handed back.
        module Zig
          # What every compile is held to. The generated C is written to give no warnings at
          # all, so any warning is a mistake in the generator and stops the build. The two
          # conversion warnings are the ones that matter most: a number squeezed into something
          # smaller, or a signed number read as unsigned, without going through rg_int32.h.
          WARNINGS = Ractor.make_shareable(%w[-std=c11 -Wall -Wextra -Wconversion -Wsign-conversion -Werror])

          # How hard to optimise, and whether to check for undefined behaviour while it runs.
          #   :checked  no optimisation, every undefined-behaviour check on, and the first one
          #             found stops the program with the line it happened on. What tests use.
          #   :fast     optimised as hard as a release would be, with no checks. Tests run this
          #             too, because optimisation is what turns hidden undefined behaviour into
          #             a wrong answer.
          OPTIMISE = Ractor.make_shareable({
                                             checked: %w[-O0 -g -fsanitize=undefined -fno-sanitize-recover=all],
                                             fast: %w[-O2]
                                           })

          RUNTIME_DIR = Ractor.make_shareable(File.expand_path("runtime", __dir__))

          # Raised when zig is missing, or refuses the C it was given.
          class Error < StandardError; end

          module_function

          # Compiles +sources+ (C files on disk) into one program and gives back its path.
          # +include+ is folders to find headers in; the runtime's own folder is always one.
          def compile(sources, include: [], mode: :checked)
            flags = WARNINGS + OPTIMISE.fetch(mode) + [RUNTIME_DIR, *include].flat_map { |dir| ["-I", dir] }
            key = cache_key(sources, flags)
            exe = File.join(cache_dir, key, "program")
            return exe if File.exist?(exe)

            FileUtils.mkdir_p(File.dirname(exe))
            building = "#{exe}.#{Process.pid}.#{rand(1 << 30)}" # renamed into place once whole
            run!("zig", "cc", *flags, "-o", building, *sources)
            File.rename(building, exe)
            exe
          end

          # Runs a compiled program, feeding it +input+, and gives back what it printed.
          def run(exe, input: "", env: {})
            out, err, status = Open3.capture3(env, exe, stdin_data: input)
            raise Error, "#{File.basename(exe)} stopped (#{status}):\n#{err}" unless status.success?

            out
          end

          def cache_key(sources, flags)
            digest = Digest::SHA256.new
            digest << version << "\0" << flags.join("\0")
            (sources + Dir.glob(File.join(RUNTIME_DIR, "*"))).sort.each do |path|
              digest << "\0" << File.basename(path) << "\0" << File.binread(path)
            end
            digest.hexdigest[0, 24]
          end

          def cache_dir
            File.join(Dir.tmpdir, "ruby-gba-native")
          end

          def version
            run!("zig", "version").strip
          end

          def run!(*command)
            out, err, status = Open3.capture3(*command)
            return out if status.success?

            raise Error, "#{command.first(2).join(' ')} failed:\n#{err}#{out}"
          rescue Errno::ENOENT
            raise Error, "zig was not found. This project installs it through mise: run `mise install`."
          end
        end
      end
    end
  end
end

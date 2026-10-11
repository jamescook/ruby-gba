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
        # A compile is slow next to everything else a test does, so the result is kept and
        # handed back the next time the same C is asked for with the same settings. The key is
        # a hash of the sources, every file in every folder headers are found in, every flag,
        # and zig's own version, so a change to any of them builds again.
        module Zig
          # The zig this backend is written against. The SDL package the desktop build fetches
          # wants this one too, and zig changes enough between versions that "whatever is
          # installed" is not a promise anybody could keep.
          VERSION = "0.17."

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

          # Raised when zig is missing or the wrong version, refuses the C it was given, or the
          # program it built stops with an error.
          class Error < StandardError; end

          module_function

          # Compiles +sources+ (C files on disk) into one program and gives back its path.
          # +include+ is folders to find headers in; the runtime's own folder is always one.
          def compile(sources, include: [], mode: :checked)
            folders = [RUNTIME_DIR, *include]
            flags = WARNINGS + OPTIMISE.fetch(mode) + folders.flat_map { |dir| ["-I", dir] }
            exe = File.join(cache_dir, cache_key(sources, folders, flags), "program")
            return exe if File.exist?(exe)

            FileUtils.mkdir_p(File.dirname(exe))
            building = "#{exe}.#{Process.pid}.#{rand(1 << 30)}" # renamed into place once whole
            capture_command("zig", "cc", *flags, "-o", building, *sources)
            File.rename(building, exe)
            exe
          end

          # Runs a program this built with +args+, feeding it +input+, and gives back what it
          # printed.
          def run_program(exe, args: [], input: "", env: {})
            out, err, status = Open3.capture3(env, exe, *args.map(&:to_s), stdin_data: input)
            raise Error, "#{File.basename(exe)} stopped (#{status}):\n#{err}" unless status.success?

            out
          end

          # The installed zig's version, refusing one this backend was not written against.
          def version
            found = capture_command("zig", "version").strip
            return found if found.start_with?(VERSION)

            raise Error, "this needs zig #{VERSION}x, and the zig installed is #{found}. Pin it for this " \
                         "project in mise (zig = \"0.17.0\") and run `mise install`."
          end

          def cache_key(sources, folders, flags)
            digest = Digest::SHA256.new
            digest << version << "\0" << flags.join("\0")
            files = sources + folders.flat_map { |dir| Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) } }
            files.uniq.sort.each { |path| digest << "\0" << path << "\0" << File.binread(path) }
            digest.hexdigest[0, 24]
          end

          def cache_dir = File.join(Dir.tmpdir, "ruby-gba-native")

          # Runs a command to the end and gives back what it printed; a failure raises with
          # what it printed to say why.
          def capture_command(*command)
            out, err, status = Open3.capture3(*command)
            return out if status.success?

            raise Error, "#{command.first(2).join(' ')} failed:\n#{err}#{out}"
          rescue Errno::ENOENT
            raise Error, "zig was not found. This project installs it through mise: run `mise install`."
          end

          private_class_method :cache_key, :cache_dir, :capture_command
        end
      end
    end
  end
end

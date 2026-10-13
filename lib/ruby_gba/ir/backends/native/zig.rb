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
          BUILD_FILE = Ractor.make_shareable(File.expand_path("build/build.zig", __dir__))

          # Raised when zig is missing or the wrong version, refuses the C it was given, or the
          # program it built stops with an error.
          class Error < StandardError; end

          module_function

          # Compiles +sources+ (C files on disk) into one program, with zig's C compiler alone and
          # no SDL — which needs no network and takes seconds, so it is what the tests build —
          # and gives back its path. +include+ is folders to find headers in; the runtime's own
          # folder is always one.
          def compile_without_sdl(sources, include: [], mode: :checked)
            refresh_checker_flags_in_checkout
            folders = [RUNTIME_DIR, *include]
            flags = WARNINGS + OPTIMISE.fetch(mode) + folders.flat_map { |dir| ["-I", dir] }
            exe = File.join(compiled_programs_dir, cache_key(sources, folders, flags), "program")
            return exe if File.exist?(exe)

            FileUtils.mkdir_p(File.dirname(exe))
            building = "#{exe}.#{Process.pid}.#{rand(1 << 30)}" # renamed into place once whole
            capture_command("zig", "cc", *flags, "-o", building, *sources)
            File.rename(building, exe)
            exe
          end

          # Builds +sources+ (C files in +src_dir+) and SDL3 into one program called +name+, with
          # zig's build system (build/build.zig), and gives back where it landed under +prefix+.
          # SDL is fetched and compiled into a cache kept between builds and shared by every
          # game, so only the first build pays for it. Raises, as #version does, on a zig this
          # was not written against.
          def build_with_sdl(src_dir, sources, name:, prefix:)
            version
            capture_command("zig", "build", "--build-file", BUILD_FILE,
                            "--cache-dir", File.join(sdl_build_cache_dir, "cache"),
                            "--pkg-dir", File.join(sdl_build_cache_dir, "packages"),
                            "-p", prefix, "-Dsrc_dir=#{src_dir}", *sources.map { |file| "-Dsources=#{file}" },
                            "-Dname=#{name}", "-Doptimize=ReleaseFast")
            File.join(prefix, "bin", Gem.win_platform? ? "#{name}.exe" : name)
          ensure
            # After the build, which is what fetches SDL and its headers — and after one that
            # fetched them and then failed, too.
            refresh_checker_flags_in_checkout
          end

          # Where the desktop builds keep what zig compiled — SDL above all — between builds.
          def sdl_build_cache_dir = File.join(Dir.home, ".cache", "ruby-gba", "native")

          # --- for an editor's C checker ---
          #
          # An editor that checks C as it is typed (clangd is the usual one) reads the runtime's
          # files on its own, knowing nothing of how they are built. With no flags it holds them
          # to none of the build's warnings, and with no folders to find headers in it reports
          # every name SDL declares as one nobody declared. It looks in a C file's folder, and
          # then each folder above it, for a compile_flags.txt, one flag to a line, and reads
          # the file with those.
          #
          # So the flags are written from here, from the same list a compile is handed (WARNINGS;
          # build/build.zig keeps a copy for the desktop build, which a test holds to it). The
          # file names folders on this machine, so it is written rather than checked
          # in — and NOBODY RUNS ANYTHING TO GET IT: every build looks at it and writes it again
          # when it is out of date (#refresh_checker_flags_in_checkout). A fresh checkout has it after its
          # first build, the build that fetches SDL adds SDL's folder to it, and a change to the
          # build's flags reaches it on the next build. It sits one folder above the runtime and
          # not in it, because every file in the runtime's folder is part of what a compile is
          # remembered by (#cache_key).
          #
          # WHAT THE FLAGS DO NOT CURE. A checker keeps its reading of a header between edits.
          # When a header changes and it has not caught up, it reads the file's new text at the
          # old positions and reports nonsense from the middle of a comment ("invalid suffix on
          # integer constant", on a line that only names a number the header defines). That
          # goes when it reads the header again, and it is not a fault in the code. To ask the
          # compiler itself:
          #
          #   rake test:native TEST=test/ruby_gba/ir/backends/native/test_native_checker_flags.rb

          CHECKER_FLAGS_FILE = Ractor.make_shareable(File.expand_path("compile_flags.txt", __dir__))

          # What the build holds the runtime to, and where its headers are found: its own folder,
          # and SDL's once a desktop build has fetched it.
          def checker_flags = WARNINGS + [RUNTIME_DIR, sdl_include_dir].compact.map { |dir| "-I#{dir}" }

          # Writes them to +path+ unless it already holds exactly them, and says whether it
          # wrote. The file is put in place whole, so a checker never reads half of one; what is
          # being written meanwhile is named after the file, so git and the gem leave it out too.
          def refresh_checker_flags(path = CHECKER_FLAGS_FILE)
            wanted = checker_flags.map { |flag| "#{flag}\n" }.join
            return false if File.exist?(path) && File.read(path) == wanted

            writing = "#{path}.#{Process.pid}.#{rand(1 << 30)}"
            File.write(writing, wanted)
            File.rename(writing, path)
            true
          end

          # What every build does about that file: the same, where somebody is working on the
          # runtime's C, and nothing anywhere else. A folder that cannot be written is no reason
          # to stop a build.
          def refresh_checker_flags_in_checkout
            refresh_checker_flags if working_in_checkout?
          rescue SystemCallError
            nil
          end

          # Whether the build was started from inside a git checkout of this library — which
          # is where its own tests and tools are run. A game that takes the library from git has
          # a checkout of it too, in bundler's folder, but is built from the game's own folder,
          # so that copy is not written into.
          def working_in_checkout?
            root = File.expand_path("../../../../..", __dir__)
            File.exist?(File.join(root, ".git")) && "#{Dir.pwd}/".start_with?("#{root}/")
          end

          # The folder the newest SDL fetched on this machine keeps its headers in, or nil before
          # the first desktop build. An older SDL left beside it is not named: headers from two
          # of them, with the old ones found first, is what a checker must not be given.
          def sdl_include_dir
            Dir.glob(File.join(sdl_build_cache_dir, "packages", "*", "include"))
               .select { |dir| File.exist?(File.join(dir, "SDL3", "SDL.h")) }
               .max_by { |dir| File.mtime(dir) }
          end

          # Runs a program this built with +args+, feeding it +input+, and gives back what it
          # printed. One still running after +seconds+ is stopped and reported: a game that loops
          # without ever waiting for the screen never ends on its own, where the interpreter
          # stops it at its step budget.
          #
          # WHAT IT READS AND PRINTS ARE FILES, read back once it has ended, and not pipes read
          # while it runs. A pipe holds a little and then makes the program wait for its reader,
          # and a reader in Ruby takes its turn again for every piece, behind every other thread
          # that is busy, since Ruby runs one thread at a time. Beside a few busy threads a
          # program that ends in a second took minutes that way, and +seconds+ ran out on a
          # program that was only waiting to be read. Through files its run is its own.
          def run_program(exe, args: [], input: "", env: {}, seconds: 60)
            Dir.mktmpdir("ruby-gba-run") do |dir|
              fed, printed, complained = %w[fed printed complained].map { |name| File.join(dir, name) }
              File.binwrite(fed, input)
              pid = Process.spawn(env, exe, *args.map(&:to_s), in: fed, out: printed, err: complained,
                                                               rlimit_fsize: MOST_PRINTED_BYTES)
              waiter = Process.detach(pid)
              begin
                finished = waiter.join(seconds)
              ensure
                # Stopped on every way out that leaves it running: out of time, or this thread
                # interrupted while it waited. The folder it prints into goes when this returns.
                stop_program(pid) if waiter.alive?
              end
              status = waiter.value
              raise Error, "#{File.basename(exe)} was still running after #{seconds} seconds, and was stopped" unless finished
              raise Error, "#{File.basename(exe)} stopped (#{status}):\n#{File.read(complained)}" unless status.success?

              File.read(printed)
            end
          end

          # The most a program run by #run_program may print before the system stops it. What it
          # prints is kept in a file, and a game stuck in a loop that prints on every pass would
          # otherwise fill the disk for as long as it is given. A long run that prints every
          # frame's picture comes to a small part of this.
          MOST_PRINTED_BYTES = 2 * 1024 * 1024 * 1024

          # Ends a program that may already have ended.
          def stop_program(pid)
            Process.kill(:KILL, pid)
          rescue Errno::ESRCH
            nil
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

          # Where programs compiled without SDL are kept, by the hash of what made them.
          def compiled_programs_dir = File.join(Dir.tmpdir, "ruby-gba-native")

          # Runs a command to the end and gives back what it printed; a failure raises with
          # what it printed to say why.
          def capture_command(*command)
            out, err, status = Open3.capture3(*command)
            return out if status.success?

            raise Error, "#{command.first(2).join(' ')} failed:\n#{err}#{out}"
          rescue Errno::ENOENT
            raise Error, "zig was not found. This project installs it through mise: run `mise install`."
          end

          private_class_method :cache_key, :compiled_programs_dir, :sdl_build_cache_dir, :capture_command,
                               :refresh_checker_flags_in_checkout, :working_in_checkout?
        end
      end
    end
  end
end

# frozen_string_literal: true

require "mkmf"

# gemba-core links only libmgba (+ its own deps: zlib, libpng, libzip). No
# SDL2, no Tk — this is the headless core for dev/test verification. rcheevos
# (RetroAchievements) is opt-in and compiled out by default; see the bottom.

def add_mgba_deps
  # Dependencies libmgba pulls in, needed when linking the static archive.
  $libs << " -lz" unless $libs.include?("-lz")
  $libs << " -lm" unless $libs.include?("-lm")
  $libs << " -lpthread" unless $libs.include?("-lpthread")

  # libmgba's static build also links libpng and libzip.
  pkg_config("libpng") || ($libs << " -lpng" unless $libs.include?("-lpng"))
  pkg_config("libzip") || ($libs << " -lzip" unless $libs.include?("-lzip"))

  # macOS: CoreFoundation for config directory resolution.
  if RUBY_PLATFORM =~ /darwin/
    $LDFLAGS << " -framework CoreFoundation" unless $LDFLAGS.include?("CoreFoundation")
  end
end

def check_mgba
  have_header("mgba/core/core.h") or return false
  # Try with deps first (needed for static linking on macOS, where
  # -undefined dynamic_lookup hides missing symbols until runtime).
  saved_libs = $libs.dup
  add_mgba_deps
  return true if have_library("mgba")

  # Fall back without deps (shared lib on Linux — deps baked into the .so).
  $libs = saved_libs
  have_library("mgba")
end

def find_mgba
  # 1. MGBA_DIR env var (explicit override — e.g. a local libmgba build).
  if ENV["MGBA_DIR"]
    dir = ENV["MGBA_DIR"]
    $INCFLAGS << " -I#{dir}/include"
    $LDFLAGS << " -L#{dir}/lib"
    return true if check_mgba

    abort "MGBA_DIR=#{dir} set but libmgba not found there"
  end

  # 2. pkg-config.
  if pkg_config("mgba")
    add_mgba_deps
    return true
  end

  # 3. Homebrew / common prefixes (macOS) and system paths (Linux).
  search_prefixes = [
    "/opt/homebrew", # Apple Silicon Homebrew
    "/usr/local",    # Intel Homebrew / manual builds
    "/usr"           # System
  ]

  # Debian/Ubuntu multiarch lib dirs (e.g. /usr/lib/aarch64-linux-gnu).
  multiarch_dirs = Dir.glob("/usr/lib/*-linux-gnu").select { |d| File.directory?(d) }

  search_prefixes.each do |prefix|
    inc = "#{prefix}/include"
    next unless File.exist?("#{inc}/mgba/core/core.h")

    $INCFLAGS << " -I#{inc}"
    multiarch_dirs.each { |d| $LDFLAGS << " -L#{d}" unless $LDFLAGS.include?(d) }
    $LDFLAGS << " -L#{prefix}/lib" unless $LDFLAGS.include?("#{prefix}/lib")
    return true if check_mgba
  end

  false
end

unless find_mgba
  abort <<~MSG
    libmgba not found. Install it:

      macOS:   brew install mgba
      Debian:  sudo apt install libmgba-dev
      Fedora:  build from source

    Or point at a local build with MGBA_DIR=/path/to/mgba/install
  MSG
end

# --- rcheevos (RetroAchievements) — opt-in, off by default ----------------
#
# Reintroducing achievement evaluation is flip-a-flag, no code surgery: set
# GEMBA_CORE_RCHEEVOS to the rcheevos checkout root (the one with
# src/rcheevos/runtime.c). We then define the guard macro, add the include
# paths, and append the rcheevos sources to the compile line. Left unset, the
# ext is just gemba_core_ext.c against libmgba.
$srcs = %w[gemba_core_ext.c]

if (rcheevos_root = ENV["GEMBA_CORE_RCHEEVOS"])
  runtime_c = "#{rcheevos_root}/src/rcheevos/runtime.c"
  abort "GEMBA_CORE_RCHEEVOS=#{rcheevos_root} but #{runtime_c} not found" \
    unless File.exist?(runtime_c)

  $defs << "-DGEMBA_CORE_RCHEEVOS"
  $INCFLAGS << " -I#{rcheevos_root}/include"
  $INCFLAGS << " -I#{rcheevos_root}/src/rcheevos"
  $INCFLAGS << " -I#{rcheevos_root}/src"

  $VPATH << "#{rcheevos_root}/src/rcheevos"
  $VPATH << "#{rcheevos_root}/src"
  $VPATH << "#{rcheevos_root}/src/rhash"

  # Core evaluation engine + md5 (needed by runtime.c / runtime_progress.c).
  # Excludes the HTTP client, ROM hash, and rapi.
  $srcs += %w[
    alloc.c condition.c condset.c format.c lboard.c memref.c
    operand.c richpresence.c runtime.c runtime_progress.c
    trigger.c value.c
    rc_compat.c rc_util.c
    md5.c
  ]
end

create_makefile("gemba_core_ext")

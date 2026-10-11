// Builds one game as one executable, from C files the Ruby side has already
// written into a directory: the generated game.c and the hand-written runtime.
//
//   zig build -Dsrc_dir=/path/to/c -Dsources=game.c -Dsources=rg_sdl.c \
//             -Dname=pong -Doptimize=ReleaseFast -p /path/to/out
//
// leaves /path/to/out/bin/pong. SDL3 is compiled from its own sources and
// linked in statically, so the executable needs nothing beside it but the
// operating system. (The tests build without SDL, and without this file: see
// Native::Zig.compile_without_sdl.)
//
// Always pass --cache-dir and --pkg-dir too. Left out, zig writes .zig-cache/
// and zig-pkg/ next to this file, which is inside the installed gem. Give
// every game the SAME --cache-dir: compiled SDL is kept there, so it is
// compiled once rather than once per game.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const name = b.option([]const u8, "name", "What to call the executable (default: game)") orelse "game";
    const src_dir_option = b.option(std.Build.LazyPath, "src_dir", "Directory holding the C files, and the headers they include");
    const sources_option = b.option([]const []const u8, "sources", "A C file in src_dir to compile; say it once per file");

    // Missing either is a failed build rather than an exit here, so that
    // `zig build --help` still works without them.
    const src_dir = src_dir_option orelse return failInstall(b, "-Dsrc_dir=<directory of C files> is required");
    const sources = sources_option orelse return failInstall(b, "-Dsources=<file.c> is required, once per C file in src_dir");

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Our own files are held to the strictest warnings, and a warning stops
    // the build: the C is generated, so a warning in it is a bug in the
    // generator, and nobody is going to read the C to notice it otherwise.
    // SDL's sources are compiled by SDL's build with SDL's own flags; these
    // flags never reach them.
    mod.addCSourceFiles(.{
        .root = src_dir,
        .files = sources,
        // The same rules the tests compile the game with (Native::Zig::WARNINGS), so the
        // program a player runs is held to what the tests checked.
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wconversion", "-Wsign-conversion", "-Werror" },
    });
    mod.addIncludePath(src_dir);

    // lazyDependency hands back null on the first pass when SDL has not been
    // downloaded yet; zig then fetches it and runs this file again.
    if (b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
    })) |sdl| {
        // Linking the library also puts its headers on the include path, so
        // the runtime writes #include <SDL3/SDL.h>. The macOS frameworks SDL
        // needs (Cocoa, Metal, CoreAudio...) come with it.
        mod.linkLibrary(sdl.artifact("SDL3"));
    }

    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    b.installArtifact(exe);
}

fn failInstall(b: *std.Build, message: []const u8) void {
    b.getInstallStep().dependOn(&b.addFail(message).step);
}

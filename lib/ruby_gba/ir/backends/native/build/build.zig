// Builds one game as one executable, from C files the Ruby side has already
// written into a directory: the generated game.c and the hand-written runtime.
//
//   zig build -Dsrc_dir=/path/to/c -Dsources=game.c -Dsources=rg_sdl.c \
//             -Dname=pong -Doptimize=ReleaseFast -p /path/to/out
//
// leaves /path/to/out/bin/pong. SDL3 is compiled from its own sources and
// linked in statically, so the executable needs nothing beside it but the
// operating system.
//
// The menu is in every program this builds: Dear ImGui (fetched by zig, pinned
// and checked by hash in build.zig.zon) is compiled into a library of its own,
// and src_dir's rg_menu.cpp, which draws the menu with it, into the program,
// both with libc++. A program a person plays always has the menu; the builds
// that leave it out are the tests', which do not come through here. (The tests
// build without SDL, and without this file: see Native::Zig.compile_without_sdl.)
//
// Always pass --cache-dir and --pkg-dir too. Left out, zig writes .zig-cache/
// and zig-pkg/ next to this file, which is inside the installed gem. Give
// every game the SAME --cache-dir: compiled SDL and Dear ImGui are kept there,
// so each is compiled once rather than once per game.

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
        .link_libcpp = true,
    });

    // Our own files are held to the strictest warnings, and a warning stops
    // the build: the C is generated, so a warning in it is a bug in the
    // generator, and nobody is going to read the C to notice it otherwise.
    // SDL's sources are compiled by SDL's build with SDL's own flags; these
    // flags never reach them.
    mod.addCSourceFiles(.{
        .root = src_dir,
        .files = sources,
        // The same rules the tests compile the game with (Native::Zig.WARNINGS), so the
        // program a player runs is held to what the tests checked.
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wconversion", "-Wsign-conversion", "-Werror" },
    });
    mod.addIncludePath(src_dir);

    // lazyDependency hands back null on the first pass when a package has not
    // been downloaded yet; zig then fetches it and runs this file again.
    const sdl_dependency = b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
    });
    const imgui_dependency = b.lazyDependency("imgui", .{});

    if (sdl_dependency) |sdl| {
        // Linking the library also puts its headers on the include path, so
        // the runtime writes #include <SDL3/SDL.h>. The macOS frameworks SDL
        // needs (Cocoa, Metal, CoreAudio...) come with it.
        mod.linkLibrary(sdl.artifact("SDL3"));
    }

    if (sdl_dependency) |sdl| if (imgui_dependency) |imgui| {
        // Dear ImGui is compiled without its demo and debug windows, which are most of its size
        // and which nothing here shows, and the same defines are given to our file that includes
        // it, since they change what its header declares. Its warnings are its author's to fix,
        // not ours: only rg_menu.cpp is held to ours.
        const defines = [_][]const u8{ "-DIMGUI_DISABLE_DEMO_WINDOWS", "-DIMGUI_DISABLE_DEBUG_TOOLS" };
        const cpp_flags = [_][]const u8{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } ++ defines;

        // A library of its own, so that it is compiled once and every game after the first links
        // it from the cache: its files are never given the game's folder, which is a new one for
        // every build and would make zig compile them again each time.
        const imgui_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        imgui_mod.addCSourceFiles(.{
            .root = imgui.path("."),
            .files = &.{
                "imgui.cpp",
                "imgui_draw.cpp",
                "imgui_tables.cpp",
                "imgui_widgets.cpp",
                "backends/imgui_impl_sdl3.cpp",
                "backends/imgui_impl_sdlrenderer3.cpp",
            },
            .flags = &cpp_flags,
        });
        imgui_mod.addIncludePath(imgui.path("."));
        imgui_mod.addIncludePath(imgui.path("backends"));
        imgui_mod.linkLibrary(sdl.artifact("SDL3")); // the backends read SDL's headers
        const imgui_lib = b.addLibrary(.{ .name = "imgui", .linkage = .static, .root_module = imgui_mod });

        mod.addIncludePath(imgui.path("."));
        mod.addIncludePath(imgui.path("backends"));
        mod.linkLibrary(imgui_lib);
        mod.addCSourceFiles(.{
            .root = src_dir,
            .files = &.{"rg_menu.cpp"},
            .flags = &(cpp_flags ++ [_][]const u8{ "-Wall", "-Wextra", "-Werror" }),
        });
    };

    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    b.installArtifact(exe);
}

fn failInstall(b: *std.Build, message: []const u8) void {
    b.getInstallStep().dependOn(&b.addFail(message).step);
}

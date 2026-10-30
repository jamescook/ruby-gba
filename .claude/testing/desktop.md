# The native desktop window

What only the windowed desktop build does, and how each part is tested.

**Input.** Keys are pressed through SDL (`--scripted-keys`, in `test_native_desktop.rb`, under
`SDL=1`): each is a real key event, onto the gamepad the keyboard is, round the window's frame
loop. Feeding buttons to the windowless program skips all of that, so a fault in how the window
reads a key shows only there.

**Retina.** SDL's stand-in display has one pixel to a point, so a fault only at a screen's own
scale (the menu drawn at half size, its text cut off) passes there. One test in
`test_native_desktop.rb` opens a real window on a Mac for that. A check of what the menu draws
looks for its text (near-white pixels), never only for something lit — an empty box is lit too.

**The save file.** Tested on a few-line game that keeps a count: the file holds the bytes the
interpreter's save memory does, is read before the game starts, is written while it runs, and
lands in a folder named for the game among the player's files. `--save-file PATH` keeps the save
there instead, which keeps a test (or a person trying something) out of real saves. When the
window writes the file is plain counting in `runtime/rg_save.c`, tested with no window
(`test_native_save_file.rb`). Small made-up programs that save go in `test_native_saves.rb`.

**How evenly it shows its pictures** cannot be seen by a test, and a stutter is exactly that. A
build started with `--frame-times` says at its end, on the error stream, what paced its frames
(the monitor or the console's clock), how far apart pictures were handed to the display, which
gaps were more than two milliseconds from the middle one, and whether sound was thrown away or
ran dry. A stutter is a clump of uneven gaps every few seconds; scattered single ones are the
computer being busy. `--refresh-rate 144` makes it choose its pacing as for that monitor; only
the choice is pretended, so `--refresh-rate 120` on a 60Hz monitor shows each picture for two
refreshes and plays at half speed. The pacing rule and the limit behind a hidden window are plain
arithmetic in `runtime/rg_pacing.h`, tested as that (`test_native_pacing.rb`).

**An editor's complaints about the runtime's C are not the build's.** An editor's C checker reads
`lib/vblank/ir/backends/native/runtime/` on its own. Every native build writes a
`compile_flags.txt` above that folder with the build's own flags and header folders
(`Native::Zig.checker_flags`), so the checker holds the code to what the build does and finds
SDL's headers; the test harnesses (`test/lowering/native/vblank/ir/backends/native/*_harness.c`) get one too.
After a header is edited the checker can keep reading it at old positions and report nonsense
("invalid suffix on integer constant" on a line naming a defined number). Ask the compiler before
believing it:
`rake test:lowering:native TEST=test/lowering/native/vblank/ir/backends/native/test_native_checker_flags.rb`.

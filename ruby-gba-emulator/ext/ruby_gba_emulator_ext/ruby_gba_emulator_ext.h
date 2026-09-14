#ifndef RUBY_GBA_EMULATOR_EXT_H
#define RUBY_GBA_EMULATOR_EXT_H

#include <ruby.h>
/* FIRST, BEFORE ANY OTHER mGBA HEADER. This is the record of how the installed library was
 * actually built, and several of mGBA's structs change SHAPE with it — the core object
 * grows five function pointers when the debugger is compiled in. Nothing else in the
 * installed headers includes it, so without this line we compile against a different struct
 * from the one the library uses, and every field past that point sits at the wrong offset.
 * Reading it here rather than naming the flags ourselves means we match whatever that
 * library was configured with instead of guessing. */
#include <mgba/flags.h>
#include <mgba/core/core.h>
#include <mgba/core/config.h>
#include <mgba/core/directories.h>
#include <mgba/core/log.h>
#include <mgba-util/vfs.h>
#include <mgba/internal/gba/bios.h>
#include <mgba/internal/gba/gba.h>
#include <mgba/internal/gba/io.h>
#include <mgba/debugger/debugger.h>

extern VALUE mRubyGBAEmulator;

void Init_ruby_gba_emulator_ext(void);

#endif /* RUBY_GBA_EMULATOR_EXT_H */

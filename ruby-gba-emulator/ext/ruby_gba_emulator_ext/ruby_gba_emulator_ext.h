#ifndef RUBY_GBA_EMULATOR_EXT_H
#define RUBY_GBA_EMULATOR_EXT_H

#include <ruby.h>
#include <mgba/core/core.h>
#include <mgba/core/config.h>
#include <mgba/core/directories.h>
#include <mgba/core/log.h>
#include <mgba-util/vfs.h>
#include <mgba/internal/gba/bios.h>
#include <mgba/internal/gba/gba.h>

extern VALUE mRubyGBAEmulator;

void Init_ruby_gba_emulator_ext(void);

#endif /* RUBY_GBA_EMULATOR_EXT_H */

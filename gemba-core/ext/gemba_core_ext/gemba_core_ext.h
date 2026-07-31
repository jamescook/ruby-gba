#ifndef GEMBA_CORE_EXT_H
#define GEMBA_CORE_EXT_H

#include <ruby.h>
#include <mgba/core/core.h>
#include <mgba/core/config.h>
#include <mgba/core/directories.h>
#include <mgba/core/log.h>
#include <mgba-util/vfs.h>
#include <mgba/internal/gba/bios.h>
#include <mgba/internal/gba/gba.h>

extern VALUE mGembaCore;

void Init_gemba_core_ext(void);

#endif /* GEMBA_CORE_EXT_H */

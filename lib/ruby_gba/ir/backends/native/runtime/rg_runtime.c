/*
 * What rg_runtime.h promises the game, handed to the driver that started the program (see
 * rg_driver.h). Nothing here knows whether there is a window.
 */
#include <stdlib.h>
#include "rg_runtime.h"
#include "rg_driver.h"
#include "rg_screen.h"
#include "rg_sound.h"

const rg_driver *rg_active_driver;

#define ALL_BUTTONS 0x3FFu

static uint32_t held;    /* buttons down now, a bit each */
static uint32_t seen;    /* ...and at the last frame boundary, to tell a press from a hold */
static uint32_t pressed; /* buttons that went down at the last frame boundary */

/* A button counts as pressed on the one frame it goes down, however long it is then held — the
 * edge the interpreter's read_buttons finds. */
void rg_buttons_read(uint32_t now) {
  held = now & ALL_BUTTONS;
  pressed = held & ~seen;
  seen = held;
}

void rg_wait_vblank(void) { rg_active_driver->wait_vblank(); }

void rg_frame_begins(void) {
  rg_screen_frame_started();
  rg_music_frame();
}

/* A driver's halt and fault never come back; abort() is only there to say so to the compiler. */
_Noreturn void rg_halt(void) {
  rg_active_driver->halt();
  abort();
}

_Noreturn void rg_fault(const char *format, ...) {
  va_list args;
  va_start(args, format);
  rg_active_driver->fault(format, args);
  va_end(args);
  abort();
}

void rg_dump_variable(const char *name, int32_t value) { rg_active_driver->dump_variable(name, value); }

/* A button's bit in +buttons+, or any of them for -1. */
static int32_t button_down(uint32_t buttons, int32_t button) {
  if (button < 0) return buttons != 0;
  return (int32_t)((buttons >> button) & 1u);
}

int32_t rg_held(int32_t button) { return button_down(held, button); }
int32_t rg_pressed(int32_t button) { return button_down(pressed, button); }

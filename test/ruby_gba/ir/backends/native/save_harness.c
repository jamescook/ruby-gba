/*
 * Asks runtime/rg_save.c when a driver that keeps the save in a file would write it, a line of
 * standard input each. See test_native_save_file.rb.
 *
 *   play FRAMES SAVING WRITES
 *                  plays FRAMES frames. The game saves a byte during each of the first SAVING of
 *                  them. At the end of every frame the driver asks whether the file is due, as
 *                  the window does, and where it is, writes it (WRITES 1) or fails to (WRITES
 *                  0). Prints the frames the file was due at the end of.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include "rg_runtime.h"
#include "rg_save.h"

/* The 32K memory that takes any byte: 32768 bytes, none wiped together, 0xFF where nothing has
 * written and 0x00 for a byte being wiped. */
const int32_t rg_game_save_memory[] = {32768, 0, 0xFF, 0x00};

_Noreturn void rg_halt(void) { exit(3); }

_Noreturn void rg_fault(const char *format, ...) {
  va_list args;
  va_start(args, format);
  vfprintf(stderr, format, args);
  va_end(args);
  exit(1);
}

int main(void) {
  long frames, saving;
  int writes;
  while (scanf(" play %ld %ld %d", &frames, &saving, &writes) == 3) {
    for (long frame = 1; frame <= frames; frame++) {
      if (frame <= saving) rg_save_write(0, (int32_t)frame, 1);
      if (!rg_save_file_is_due()) continue;
      printf("%ld ", frame);
      if (writes) rg_save_file_written();
    }
    printf("unwritten %d\n", rg_save_unwritten());
  }
  return 0;
}

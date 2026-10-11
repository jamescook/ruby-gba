/*
 * The start of a build with no window at all — what the tests compile, so they need neither SDL
 * nor a network to fetch it. A player's build starts in rg_sdl.c instead, and reaches the same
 * windowless runtime with --headless.
 */
#include "rg_driver.h"

int main(int argc, char **argv) { return rg_headless_main(argc, argv); }

#include "gemba_core_ext.h"
#ifdef GEMBA_CORE_RCHEEVOS
#include "rc_runtime.h"
#endif
#include <mgba/core/config.h>
#include <mgba/core/serialize.h>
#include <ruby/thread.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <fcntl.h>

/*
 * gemba-core — a headless libmgba binding for dev/test verification.
 *
 * This is a lean copy of gemba's native core: it steps a ROM one frame at a
 * time and hands back the video/audio buffers and bus memory, with no SDL2 or
 * Tk anywhere (those live only in gemba's pure-Ruby frontend). The
 * RetroAchievements (rcheevos) evaluator is present but compiled out by
 * default — build with GEMBA_CORE_RCHEEVOS defined (and the rcheevos sources on
 * the compile line) to bring it back without touching this file.
 */

/*
 * Forward declarations for blip_buf (audio buffer API).
 * These functions are part of libmgba but the header may
 * not be in the installed include path.
 */
struct blip_t;
int blip_samples_avail(const struct blip_t *);
int blip_read_samples(struct blip_t *, short out[], int count, int stereo);
void blip_set_rates(struct blip_t *, double clock_rate, double sample_rate);

VALUE mGembaCore;
static VALUE cCore;
#ifdef GEMBA_CORE_RCHEEVOS
static VALUE ra_empty_array; /* frozen [] returned by do_frame when nothing triggered */
#endif

/* No-op logger — prevents segfault when mGBA tries to log
 * without a logger configured (the default is NULL). */
static void
null_log(struct mLogger *logger, int category, enum mLogLevel level,
         const char *format, va_list args)
{
    (void)logger; (void)category; (void)level;
    (void)format; (void)args;
}

static struct mLogger s_null_logger = {
    .log = null_log,
    .filter = NULL,
};

/* GBA key indices (bit positions for set_keys bitmask).
 * Matches mGBA's GBA_KEY_* enum. */
#define GEMBA_KEY_A      0
#define GEMBA_KEY_B      1
#define GEMBA_KEY_SELECT 2
#define GEMBA_KEY_START  3
#define GEMBA_KEY_RIGHT  4
#define GEMBA_KEY_LEFT   5
#define GEMBA_KEY_UP     6
#define GEMBA_KEY_DOWN   7
#define GEMBA_KEY_R      8
#define GEMBA_KEY_L      9

/* --------------------------------------------------------- */
/* GBA color correction (Pokefan531 / Color Mangler formula)  */
/*                                                           */
/* The GBA LCD has a non-standard gamma (~3.2) and channel   */
/* cross-talk. Games were designed with exaggerated colors    */
/* to compensate. This LUT maps raw mGBA ARGB8888 output to  */
/* corrected sRGB values that approximate the original GBA    */
/* LCD appearance.                                           */
/*                                                           */
/* 32x32x32 entries (one per RGB555 input color) = 128KB.    */
/* Built once on enable; applied per-pixel in video_buffer_argb. */
/*                                                           */
/* Reference: libretro gba-color.glsl (public domain)        */
/*   https://github.com/libretro/glsl-shaders/blob/master/   */
/*   handheld/shaders/color/gba-color.glsl                   */
/* --------------------------------------------------------- */

static uint32_t gba_color_lut[32][32][32];
static int gba_color_lut_built = 0;

static void
build_gba_color_lut(void)
{
    const double target_gamma  = 2.2;
    const double darken_screen = 1.0;
    const double display_gamma = 2.2;
    const double lum           = 0.94;
    const double input_gamma   = target_gamma + darken_screen; /* 3.2 */

    for (int ri = 0; ri < 32; ri++) {
        for (int gi = 0; gi < 32; gi++) {
            for (int bi = 0; bi < 32; bi++) {
                double r = pow(ri / 31.0, input_gamma) * lum;
                double g = pow(gi / 31.0, input_gamma) * lum;
                double b = pow(bi / 31.0, input_gamma) * lum;
                if (r > 1.0) r = 1.0;
                if (g > 1.0) g = 1.0;
                if (b > 1.0) b = 1.0;

                /* Pokefan531 mixing matrix */
                double nr =  0.82  * r + 0.125 * g + 0.195 * b;
                double ng =  0.24  * r + 0.665 * g + 0.075 * b;
                double nb = -0.06  * r + 0.21  * g + 0.73  * b;

                if (nr < 0.0) nr = 0.0; if (nr > 1.0) nr = 1.0;
                if (ng < 0.0) ng = 0.0; if (ng > 1.0) ng = 1.0;
                if (nb < 0.0) nb = 0.0; if (nb > 1.0) nb = 1.0;

                nr = pow(nr, 1.0 / display_gamma);
                ng = pow(ng, 1.0 / display_gamma);
                nb = pow(nb, 1.0 / display_gamma);

                uint8_t or8 = (uint8_t)(nr * 255.0 + 0.5);
                uint8_t og8 = (uint8_t)(ng * 255.0 + 0.5);
                uint8_t ob8 = (uint8_t)(nb * 255.0 + 0.5);

                gba_color_lut[ri][gi][bi] =
                    0xFF000000 | ((uint32_t)or8 << 16) |
                    ((uint32_t)og8 << 8) | (uint32_t)ob8;
            }
        }
    }
    gba_color_lut_built = 1;
}

/* Apply LUT to an ARGB8888 pixel. The GBA only outputs 15-bit color
 * (RGB555), so we quantize each 8-bit channel to 5 bits for lookup. */
static inline uint32_t
color_correct_pixel(uint32_t argb)
{
    int r5 = (int)((argb >> 16) & 0xFF) >> 3;
    int g5 = (int)((argb >>  8) & 0xFF) >> 3;
    int b5 = (int)((argb      ) & 0xFF) >> 3;
    return gba_color_lut[r5][g5][b5];
}

struct mgba_core {
    struct mCore *core;
    color_t *video_buffer;
    uint32_t *prev_frame;
    int width;
    int height;
    int destroyed;
    int color_correction;
    int frame_blending;
    /* Rewind ring buffer */
    int rewind_capacity;       /* number of slots (0 = disabled) */
    int rewind_head;           /* next write index */
    int rewind_count;          /* number of valid snapshots */
    size_t rewind_state_size;  /* bytes per snapshot */
    void **rewind_slots;       /* array of rewind_capacity void* buffers */
};

static void
mgba_rewind_free(struct mgba_core *mc)
{
    if (mc->rewind_slots) {
        for (int i = 0; i < mc->rewind_capacity; i++) {
            if (mc->rewind_slots[i]) {
                free(mc->rewind_slots[i]);
                mc->rewind_slots[i] = NULL;
            }
        }
        free(mc->rewind_slots);
        mc->rewind_slots = NULL;
    }
    mc->rewind_capacity = 0;
    mc->rewind_head = 0;
    mc->rewind_count = 0;
    mc->rewind_state_size = 0;
}

static void
mgba_core_cleanup(struct mgba_core *mc)
{
    mgba_rewind_free(mc);
    if (!mc->destroyed && mc->core) {
        mc->core->deinit(mc->core);
        mc->core = NULL;
    }
    if (mc->video_buffer) {
        free(mc->video_buffer);
        mc->video_buffer = NULL;
    }
    if (mc->prev_frame) {
        free(mc->prev_frame);
        mc->prev_frame = NULL;
    }
    mc->destroyed = 1;
}

static void
mgba_core_dfree(void *ptr)
{
    struct mgba_core *mc = ptr;
    mgba_core_cleanup(mc);
    xfree(mc);
}

static size_t
mgba_core_memsize(const void *ptr)
{
    const struct mgba_core *mc = ptr;
    size_t size = sizeof(struct mgba_core);
    if (mc->video_buffer) {
        size += (size_t)mc->width * mc->height * sizeof(color_t);
    }
    if (mc->prev_frame) {
        size += (size_t)mc->width * mc->height * sizeof(uint32_t);
    }
    if (mc->rewind_slots) {
        size += (size_t)mc->rewind_capacity * mc->rewind_state_size;
        size += (size_t)mc->rewind_capacity * sizeof(void *);
    }
    return size;
}

static const rb_data_type_t mgba_core_type = {
    .wrap_struct_name = "GembaCore::Core",
    .function = {
        .dmark = NULL,
        .dfree = mgba_core_dfree,
        .dsize = mgba_core_memsize,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE
mgba_core_alloc(VALUE klass)
{
    struct mgba_core *mc;
    VALUE obj = TypedData_Make_Struct(klass, struct mgba_core,
                                     &mgba_core_type, mc);
    mc->core = NULL;
    mc->video_buffer = NULL;
    mc->prev_frame = NULL;
    mc->width = 0;
    mc->height = 0;
    mc->destroyed = 0;
    mc->color_correction = 0;
    mc->frame_blending = 0;
    mc->rewind_capacity = 0;
    mc->rewind_head = 0;
    mc->rewind_count = 0;
    mc->rewind_state_size = 0;
    mc->rewind_slots = NULL;
    return obj;
}

static struct mgba_core *
get_mgba_core(VALUE self)
{
    struct mgba_core *mc;
    TypedData_Get_Struct(self, struct mgba_core, &mgba_core_type, mc);
    if (mc->destroyed || !mc->core) {
        rb_raise(rb_eRuntimeError, "mGBA core has been destroyed");
    }
    return mc;
}

/* --------------------------------------------------------- */
/* Core#initialize(rom_path, save_dir=nil)                   */
/* --------------------------------------------------------- */

static VALUE
mgba_core_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE rom_path, save_dir, bios_path;
    rb_scan_args(argc, argv, "12", &rom_path, &save_dir, &bios_path);

    struct mgba_core *mc;
    TypedData_Get_Struct(self, struct mgba_core, &mgba_core_type, mc);

    Check_Type(rom_path, T_STRING);
    const char *path = StringValueCStr(rom_path);

    /* 1. Detect platform from ROM */
    struct mCore *core = mCoreFind(path);
    if (!core) {
        rb_raise(rb_eArgError, "mCoreFind failed — unsupported ROM: %s", path);
    }

    /* 2. Initialize core + config (required per mGBA Python bindings) */
    if (!core->init(core)) {
        rb_raise(rb_eRuntimeError, "mCore init failed");
    }
    mCoreInitConfig(core, NULL);

    /* 3. Get desired video dimensions */
    unsigned w, h;
    core->desiredVideoDimensions(core, &w, &h);
    mc->width = (int)w;
    mc->height = (int)h;

    /* 4. Allocate and set video buffer */
    mc->video_buffer = calloc((size_t)w * h, sizeof(color_t));
    if (!mc->video_buffer) {
        core->deinit(core);
        rb_raise(rb_eNoMemError, "failed to allocate video buffer");
    }
    core->setVideoBuffer(core, mc->video_buffer, w);

    /* 4b. Allocate previous-frame buffer for frame blending */
    mc->prev_frame = calloc((size_t)w * h, sizeof(uint32_t));
    if (!mc->prev_frame) {
        free(mc->video_buffer);
        mc->video_buffer = NULL;
        core->deinit(core);
        rb_raise(rb_eNoMemError, "failed to allocate prev_frame buffer");
    }

    /* 5. Set audio buffer size */
    core->setAudioBufferSize(core, 2048);

    /* 6. Load ROM (convenience function handles VFile internally) */
    if (!mCoreLoadFile(core, path)) {
        free(mc->video_buffer);
        mc->video_buffer = NULL;
        free(mc->prev_frame);
        mc->prev_frame = NULL;
        core->deinit(core);
        rb_raise(rb_eArgError, "failed to load ROM: %s", path);
    }

    /* 7. Override save directory if provided */
    if (!NIL_P(save_dir)) {
        Check_Type(save_dir, T_STRING);
        struct mCoreOptions opts = { 0 };
        opts.savegamePath = (char *)StringValueCStr(save_dir);
        mDirectorySetMapOptions(&core->dirs, &opts);
    }

    /* 7b. Load BIOS if provided (must be before reset) */
    if (!NIL_P(bios_path)) {
        Check_Type(bios_path, T_STRING);
        struct VFile *bvf = VFileOpen(StringValueCStr(bios_path), O_RDONLY);
        if (bvf) {
            if (!core->loadBIOS(core, bvf, 0)) {
                bvf->close(bvf);
            }
        }
    }

    /* 8. Reset */
    core->reset(core);

    /* 8b. Re-query dimensions now that the ROM is loaded and the board
     * pointer is populated.  For GB/GBC, the pre-load query returns the
     * SGB frame size (256x224) because core->board is NULL at that point.
     * After reset the real model is known, so desiredVideoDimensions
     * returns the correct 160x144 for non-SGB games.  When the
     * dimensions shrink we must reallocate and call setVideoBuffer so
     * the stride matches the actual width. */
    {
        unsigned w2, h2;
        core->desiredVideoDimensions(core, &w2, &h2);
        if (w2 != w || h2 != h) {
            color_t *new_vbuf = calloc((size_t)w2 * h2, sizeof(color_t));
            uint32_t *new_prev = calloc((size_t)w2 * h2, sizeof(uint32_t));
            if (!new_vbuf || !new_prev) {
                free(new_vbuf);
                free(new_prev);
                free(mc->video_buffer);
                mc->video_buffer = NULL;
                free(mc->prev_frame);
                mc->prev_frame = NULL;
                core->deinit(core);
                rb_raise(rb_eNoMemError, "failed to reallocate video buffer");
            }
            free(mc->video_buffer);
            free(mc->prev_frame);
            mc->video_buffer = new_vbuf;
            mc->prev_frame = new_prev;
            core->setVideoBuffer(core, mc->video_buffer, w2);
        }
        mc->width  = (int)w2;
        mc->height = (int)h2;
    }

    /* 9. Autoload save file (.sav alongside ROM, or in save_dir).
     * Creates the .sav if it doesn't exist yet. */
    mCoreAutoloadSave(core);

    /* 10. Set blip_buf output rate to 44100 Hz (must be after reset) */
    {
        double clock_rate = (double)core->frequency(core);
        struct blip_t *left  = core->getAudioChannel(core, 0);
        struct blip_t *right = core->getAudioChannel(core, 1);
        if (!left || !right) {
            free(mc->video_buffer);
            mc->video_buffer = NULL;
            free(mc->prev_frame);
            mc->prev_frame = NULL;
            core->deinit(core);
            rb_raise(rb_eRuntimeError, "mGBA audio channels not available");
        }
        blip_set_rates(left,  clock_rate, 44100.0);
        blip_set_rates(right, clock_rate, 44100.0);
    }

    mc->core = core;
    return self;
}

/* --------------------------------------------------------- */
/* Core#run_frame — releases GVL for ~16ms of CPU work       */
/* --------------------------------------------------------- */

struct run_frame_args {
    struct mCore *core;
};

static void *
run_frame_nogvl(void *arg)
{
    struct run_frame_args *a = arg;
    a->core->runFrame(a->core);
    return NULL;
}

static VALUE
mgba_core_run_frame(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    struct run_frame_args args = { .core = mc->core };
    rb_thread_call_without_gvl(run_frame_nogvl, &args, RUBY_UBF_IO, NULL);
    return Qnil;
}

/* --------------------------------------------------------- */
/* Core#video_buffer                                         */
/* --------------------------------------------------------- */

static VALUE
mgba_core_video_buffer(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    long size = (long)mc->width * mc->height * (long)sizeof(color_t);
    return rb_str_new((const char *)mc->video_buffer, size);
}

/* --------------------------------------------------------- */
/* Core#video_buffer_argb                                    */
/* Returns pixel data with R↔B swapped for SDL ARGB8888.     */
/* mGBA color_t is 0xAABBGGRR; SDL wants 0xAARRGGBB.        */
/* --------------------------------------------------------- */

static VALUE
mgba_core_video_buffer_argb(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    long npixels = (long)mc->width * mc->height;
    long size = npixels * (long)sizeof(uint32_t);
    VALUE str = rb_str_new(NULL, size);
    uint32_t *dst = (uint32_t *)RSTRING_PTR(str);
    const uint32_t *src = (const uint32_t *)mc->video_buffer;

    if (mc->color_correction && !gba_color_lut_built)
        build_gba_color_lut();

    for (long i = 0; i < npixels; i++) {
        uint32_t px = src[i];
        /* mGBA native color_t is mCOLOR_XBGR8 (0xXXBBGGRR) — the high
         * byte is unused padding, not alpha. Force it to 0xFF so
         * consumers that interpret byte 3 as alpha (Tk photo, PNG)
         * don't get transparent pixels.
         * Ref: https://github.com/mgba-emu/mgba/blob/c30aaa8f42b5b786924d955630b29cd990176968/include/mgba-util/image.h#L62 */
        uint32_t argb = 0xFF000000
               | ((px & 0x000000FF) << 16)
               | (px & 0x0000FF00)
               | ((px & 0x00FF0000) >> 16);

        if (mc->color_correction)
            argb = color_correct_pixel(argb);

        if (mc->frame_blending && mc->prev_frame) {
            uint32_t prev = mc->prev_frame[i];
            mc->prev_frame[i] = argb;  /* store unblended for next frame */
            argb = ((argb & 0xFEFEFEFE) >> 1)
                 + ((prev & 0xFEFEFEFE) >> 1)
                 + (argb & prev & 0x01010101);
        }

        dst[i] = argb;
    }
    return str;
}

/* --------------------------------------------------------- */
/* Core#audio_buffer                                         */
/* --------------------------------------------------------- */

static VALUE
mgba_core_audio_buffer(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);

    struct blip_t *left  = mc->core->getAudioChannel(mc->core, 0);
    struct blip_t *right = mc->core->getAudioChannel(mc->core, 1);
    if (!left || !right) {
        return rb_str_new(NULL, 0);
    }

    int avail = blip_samples_avail(left);
    if (avail <= 0) {
        return rb_str_new(NULL, 0);
    }

    /* Interleaved stereo int16: L R L R ... */
    long byte_size = (long)avail * 2 * (long)sizeof(int16_t);
    VALUE str = rb_str_new(NULL, byte_size);
    int16_t *buf = (int16_t *)RSTRING_PTR(str);

    /* stereo=1: write every other sample for interleaving */
    blip_read_samples(left,  buf,     avail, 1);
    blip_read_samples(right, buf + 1, avail, 1);

    return str;
}

/* --------------------------------------------------------- */
/* Core#set_keys(bitmask)                                    */
/* --------------------------------------------------------- */

static VALUE
mgba_core_set_keys(VALUE self, VALUE keys)
{
    struct mgba_core *mc = get_mgba_core(self);
    uint32_t bitmask = NUM2UINT(keys);
    mc->core->setKeys(mc->core, bitmask);
    return Qnil;
}

/* --------------------------------------------------------- */
/* Core#width, Core#height                                   */
/* --------------------------------------------------------- */

static VALUE
mgba_core_width(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    return INT2NUM(mc->width);
}

static VALUE
mgba_core_height(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    return INT2NUM(mc->height);
}

/* --------------------------------------------------------- */
/* Core#title                                                */
/* --------------------------------------------------------- */

static VALUE
mgba_core_title(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    char title[16];
    memset(title, 0, sizeof(title));
    mc->core->getGameTitle(mc->core, title);
    title[15] = '\0';

    /* strlen stops at first null; then trim trailing spaces */
    int len = (int)strlen(title);
    while (len > 0 && title[len - 1] == ' ') len--;
    return rb_str_new(title, len);
}

/* --------------------------------------------------------- */
/* Core#game_code                                            */
/* --------------------------------------------------------- */

static VALUE
mgba_core_game_code(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    char code[16];
    memset(code, 0, sizeof(code));
    mc->core->getGameCode(mc->core, code);
    code[15] = '\0';

    /* strlen stops at first null; then trim trailing spaces */
    int len = (int)strlen(code);
    while (len > 0 && code[len - 1] == ' ') len--;
    return rb_str_new(code, len);
}

/* --------------------------------------------------------- */
/* Core#checksum                                             */
/* Returns the CRC32 checksum of the loaded ROM.             */
/* --------------------------------------------------------- */

static VALUE
mgba_core_checksum(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    uint32_t crc = 0;
    mc->core->checksum(mc->core, &crc, mCHECKSUM_CRC32);
    return UINT2NUM(crc);
}

/* --------------------------------------------------------- */
/* Core#platform                                             */
/* Returns "GBA", "GB", or "Unknown".                        */
/* --------------------------------------------------------- */

static VALUE
mgba_core_platform(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    enum mPlatform p = mc->core->platform(mc->core);
    switch (p) {
    case mPLATFORM_GBA: return rb_str_new_cstr("GBA");
    case mPLATFORM_GB:  return rb_str_new_cstr("GB");
    default:            return rb_str_new_cstr("Unknown");
    }
}

/* --------------------------------------------------------- */
/* Core#rom_size                                             */
/* --------------------------------------------------------- */

static VALUE
mgba_core_rom_size(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    size_t sz = mc->core->romSize(mc->core);
    return SIZET2NUM(sz);
}

/* --------------------------------------------------------- */
/* Core#maker_code                                           */
/* Reads the 2-byte maker/publisher code from the GBA ROM    */
/* header at offset 0xB0. Uses busRead8 at 0x080000B0.      */
/* Returns empty string for non-GBA ROMs.                    */
/* --------------------------------------------------------- */

static VALUE
mgba_core_maker_code(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA) {
        return rb_str_new_cstr("");
    }

    char maker[3];
    maker[0] = (char)mc->core->busRead8(mc->core, 0x080000B0);
    maker[1] = (char)mc->core->busRead8(mc->core, 0x080000B1);
    maker[2] = '\0';
    return rb_str_new(maker, (int)strlen(maker));
}

/* --------------------------------------------------------- */
/* Core#bus_read8(address)                                   */
/* Read one byte from the GBA address bus.                   */
/* Returns 0..255 as an Integer.                             */
/* Reads any mapped region — IWRAM, EWRAM, VRAM, registers.  */
/* --------------------------------------------------------- */

static VALUE
mgba_core_bus_read8(VALUE self, VALUE addr)
{
    struct mgba_core *mc = get_mgba_core(self);
    uint32_t address = (uint32_t)NUM2UINT(addr);
    uint8_t val = (uint8_t)mc->core->busRead8(mc->core, address);
    return UINT2NUM(val);
}

/* Core#bus_read16(address)                                  */
/* Read two bytes (little-endian) from the GBA address bus.  */
/* Returns 0..65535 as an Integer.                           */
/* --------------------------------------------------------- */

static VALUE
mgba_core_bus_read16(VALUE self, VALUE addr)
{
    struct mgba_core *mc = get_mgba_core(self);
    uint32_t address = (uint32_t)NUM2UINT(addr);
    uint16_t val = (uint16_t)mc->core->busRead16(mc->core, address);
    return UINT2NUM(val);
}

/* Core#bus_read32(address)                                  */
/* Read four bytes (little-endian) from the GBA address bus. */
/* Returns 0..4294967295 as an Integer.                      */
/* --------------------------------------------------------- */

static VALUE
mgba_core_bus_read32(VALUE self, VALUE addr)
{
    struct mgba_core *mc = get_mgba_core(self);
    uint32_t address = (uint32_t)NUM2UINT(addr);
    uint32_t val = mc->core->busRead32(mc->core, address);
    return UINT2NUM(val);
}

/* Core#save_state_to_file(path)                             */
/* Save the complete emulator state to a file.               */
/* Returns true on success, false on failure.                */
/* --------------------------------------------------------- */

static VALUE
mgba_core_save_state_to_file(VALUE self, VALUE rb_path)
{
    struct mgba_core *mc = get_mgba_core(self);
    Check_Type(rb_path, T_STRING);
    const char *path = StringValueCStr(rb_path);

    struct VFile *vf = VFileOpen(path, O_CREAT | O_TRUNC | O_WRONLY);
    if (!vf) {
        rb_raise(rb_eRuntimeError, "Cannot open state file for writing: %s", path);
    }

    bool ok = mCoreSaveStateNamed(mc->core, vf, SAVESTATE_ALL);
    vf->close(vf);
    return ok ? Qtrue : Qfalse;
}

/* --------------------------------------------------------- */
/* Core#load_state_from_file(path)                           */
/* Load emulator state from a file.                          */
/* Returns true on success, false on failure.                */
/* --------------------------------------------------------- */

static VALUE
mgba_core_load_state_from_file(VALUE self, VALUE rb_path)
{
    struct mgba_core *mc = get_mgba_core(self);
    Check_Type(rb_path, T_STRING);
    const char *path = StringValueCStr(rb_path);

    struct VFile *vf = VFileOpen(path, O_RDONLY);
    if (!vf) {
        return Qfalse;
    }

    bool ok = mCoreLoadStateNamed(mc->core, vf, SAVESTATE_ALL);
    vf->close(vf);
    return ok ? Qtrue : Qfalse;
}

/* --------------------------------------------------------- */
/* Core#color_correction=, Core#color_correction?            */
/* --------------------------------------------------------- */

static VALUE
mgba_core_set_color_correction(VALUE self, VALUE val)
{
    struct mgba_core *mc = get_mgba_core(self);
    mc->color_correction = RTEST(val) ? 1 : 0;
    if (mc->color_correction && !gba_color_lut_built) {
        build_gba_color_lut();
    }
    return val;
}

static VALUE
mgba_core_color_correction_p(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    return mc->color_correction ? Qtrue : Qfalse;
}

/* --------------------------------------------------------- */
/* Core#frame_blending=, Core#frame_blending?                */
/* --------------------------------------------------------- */

static VALUE
mgba_core_set_frame_blending(VALUE self, VALUE val)
{
    struct mgba_core *mc = get_mgba_core(self);
    mc->frame_blending = RTEST(val) ? 1 : 0;
    return val;
}

static VALUE
mgba_core_frame_blending_p(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    return mc->frame_blending ? Qtrue : Qfalse;
}

/* --------------------------------------------------------- */
/* Rewind ring buffer                                        */
/* --------------------------------------------------------- */

/*
 * Core#rewind_init(capacity)
 * Allocate a ring buffer of `capacity` state snapshots.
 * Each slot is core->stateSize() bytes. Frees any existing buffer.
 */
static VALUE
mgba_core_rewind_init(VALUE self, VALUE rb_capacity)
{
    struct mgba_core *mc = get_mgba_core(self);
    int capacity = NUM2INT(rb_capacity);
    if (capacity <= 0)
        rb_raise(rb_eArgError, "rewind capacity must be positive");

    /* Free existing rewind buffer if reinitializing */
    mgba_rewind_free(mc);

    size_t state_size = mc->core->stateSize(mc->core);
    void **slots = calloc((size_t)capacity, sizeof(void *));
    if (!slots)
        rb_raise(rb_eNoMemError, "failed to allocate rewind slot array");

    for (int i = 0; i < capacity; i++) {
        slots[i] = malloc(state_size);
        if (!slots[i]) {
            /* Clean up already-allocated slots */
            for (int j = 0; j < i; j++) free(slots[j]);
            free(slots);
            rb_raise(rb_eNoMemError, "failed to allocate rewind slot %d", i);
        }
    }

    mc->rewind_capacity = capacity;
    mc->rewind_state_size = state_size;
    mc->rewind_slots = slots;
    mc->rewind_head = 0;
    mc->rewind_count = 0;
    return Qnil;
}

/*
 * Core#rewind_deinit
 * Free all rewind buffers.
 */
static VALUE
mgba_core_rewind_deinit(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    mgba_rewind_free(mc);
    return Qnil;
}

/*
 * Core#rewind_push
 * Save current state into the next ring buffer slot.
 * Returns true on success, false if rewind not initialized.
 */
static VALUE
mgba_core_rewind_push(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (!mc->rewind_slots || mc->rewind_capacity <= 0)
        return Qfalse;

    mc->core->saveState(mc->core, mc->rewind_slots[mc->rewind_head]);
    mc->rewind_head = (mc->rewind_head + 1) % mc->rewind_capacity;
    if (mc->rewind_count < mc->rewind_capacity)
        mc->rewind_count++;
    return Qtrue;
}

/*
 * Core#rewind_pop
 * Load the oldest snapshot and clear the buffer.
 * Jumps back to the earliest saved point (~N seconds ago).
 * Returns true on success, false if no snapshots available.
 */
static VALUE
mgba_core_rewind_pop(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (!mc->rewind_slots || mc->rewind_count <= 0)
        return Qfalse;

    /* oldest = head - count (wrapped) */
    int oldest = (mc->rewind_head - mc->rewind_count + mc->rewind_capacity)
                 % mc->rewind_capacity;
    mc->core->loadState(mc->core, mc->rewind_slots[oldest]);
    mc->rewind_head = 0;
    mc->rewind_count = 0;
    return Qtrue;
}

/*
 * Core#rewind_count
 * Returns the number of valid snapshots in the buffer.
 */
static VALUE
mgba_core_rewind_count(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    return INT2NUM(mc->rewind_count);
}

/* --------------------------------------------------------- */
/* Core#destroy, Core#destroyed?                             */
/* --------------------------------------------------------- */

static VALUE
mgba_core_destroy(VALUE self)
{
    struct mgba_core *mc;
    TypedData_Get_Struct(self, struct mgba_core, &mgba_core_type, mc);
    mgba_core_cleanup(mc);
    return Qnil;
}

static VALUE
mgba_core_destroyed_p(VALUE self)
{
    struct mgba_core *mc;
    TypedData_Get_Struct(self, struct mgba_core, &mgba_core_type, mc);
    return mc->destroyed ? Qtrue : Qfalse;
}

/* --------------------------------------------------------- */
/* XOR delta for frame-diff analysis                         */
/* --------------------------------------------------------- */

/*
 * GembaCore.xor_delta(current, previous) → String
 *
 * XOR two equal-length binary strings byte-by-byte. Pair with
 * count_changed_pixels to measure how much a frame changed — the core of
 * "what moved between these two frames" in a headless probe.
 */
static VALUE
mgba_xor_delta(VALUE mod, VALUE a, VALUE b)
{
    (void)mod;
    StringValue(a);
    StringValue(b);

    long len = RSTRING_LEN(a);
    if (RSTRING_LEN(b) != len)
        rb_raise(rb_eArgError, "strings must be the same length");

    VALUE result = rb_str_new(NULL, len);
    const unsigned char *sa = (const unsigned char *)RSTRING_PTR(a);
    const unsigned char *sb = (const unsigned char *)RSTRING_PTR(b);
    unsigned char *dst = (unsigned char *)RSTRING_PTR(result);

    for (long i = 0; i < len; i++)
        dst[i] = sa[i] ^ sb[i];

    return result;
}

/*
 * GembaCore.count_changed_pixels(delta) → Integer
 *
 * Count the number of non-zero 4-byte pixels in a delta string.
 * Used alongside xor_delta to measure per-frame change rates.
 */
static VALUE
mgba_count_changed_pixels(VALUE mod, VALUE delta)
{
    (void)mod;
    StringValue(delta);

    long len = RSTRING_LEN(delta);
    const uint32_t *pixels = (const uint32_t *)RSTRING_PTR(delta);
    long count = len / 4;
    long changed = 0;

    for (long i = 0; i < count; i++) {
        if (pixels[i] != 0) changed++;
    }

    return LONG2NUM(changed);
}

/* --------------------------------------------------------- */
/* Core#bios_loaded?                                         */
/* Returns true if a BIOS VFile is attached to this core.   */
/* GBA only; returns false for other platforms.             */
/* --------------------------------------------------------- */

static VALUE
mgba_core_bios_loaded_p(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA) {
        return Qfalse;
    }
    struct GBA *gba = (struct GBA *)mc->core->board;
    return gba->biosVf ? Qtrue : Qfalse;
}

/* --------------------------------------------------------- */
/* Cycle timing — for calibrating the cost model             */
/*                                                           */
/* The GBA runs at a fixed cycle budget per frame (~280896   */
/* cycles = 228 scanlines). A game does its per-frame work,  */
/* then halts (sleeps) until the vertical-blank interrupt    */
/* wakes it. So the CPU work a ROM actually costs each frame */
/* is the cycles it spends NOT halted — which is what we     */
/* want to measure to calibrate op weights against real code. */
/* --------------------------------------------------------- */

/* Core#global_cycles — cumulative emulated master-clock cycles since reset. */
static VALUE
mgba_core_global_cycles(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA)
        rb_raise(rb_eRuntimeError, "global_cycles is GBA-only");
    struct GBA *gba = (struct GBA *)mc->core->board;
    return ULL2NUM(gba->timing.globalCycles);
}

/* Core#frame_cycles — cycles in one video frame (constant for the platform). */
static VALUE
mgba_core_frame_cycles(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    return LONG2NUM(mc->core->frameCycles(mc->core));
}

/* Core#step — advance the emulation by one step (a single mCore step, finer
 * than a whole frame). Used to measure sub-frame CPU activity. */
static VALUE
mgba_core_step(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    mc->core->step(mc->core);
    return Qnil;
}

/* Core#cpu_cycles — the ARM core's relative cycle accumulator (advances as
 * instructions execute, folded into global time at event boundaries). */
static VALUE
mgba_core_cpu_cycles(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA)
        return Qnil;
    struct GBA *gba = (struct GBA *)mc->core->board;
    return LONG2NUM(gba->cpu->cycles);
}

/* Core#cpu_halted? — true when the CPU is asleep waiting for an interrupt. */
static VALUE
mgba_core_cpu_halted_p(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA)
        return Qnil;
    struct GBA *gba = (struct GBA *)mc->core->board;
    return gba->cpu->halted ? Qtrue : Qfalse;
}

/* Core#measure_frame_busy_cycles — step through one frame's worth of emulated
 * time and return the cycles the CPU spent executing (not halted). Call it on a
 * ROM that's already reached steady state (run a few frames first) to read the
 * real per-frame CPU cost of whatever its game loop does. GBA-only. */
static VALUE
mgba_core_measure_frame_busy_cycles(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA)
        rb_raise(rb_eRuntimeError, "measure_frame_busy_cycles is GBA-only");

    struct mCore *core = mc->core;
    struct GBA *gba = (struct GBA *)core->board;

    int32_t frame_c = core->frameCycles(core);
    uint64_t start_gc = gba->timing.globalCycles;
    int64_t busy = 0;

    /* Safety cap: at worst one single-cycle step per cycle, so a frame can't
     * take more than frameCycles iterations. A generous multiple guards against
     * a step that fails to advance time (which would otherwise spin forever). */
    long guard = 0;
    long max_iters = (long)frame_c * 4;

    /* Global time (timing.globalCycles) only jumps forward on the halted
     * "fast-forward to the next event" step; while the CPU is actually
     * executing, its instruction cycles accumulate in cpu->cycles and global
     * time stays frozen. So the real CPU work is the sum of cpu->cycles gained
     * during non-halted steps. We run until one frame of global time has
     * elapsed (the halt jump that ends the frame) and add up that work.
     *
     * This is meaningful for a per-frame workload that FITS in a frame (the
     * only thing worth calibrating against). A ROM that can't finish its work
     * in one frame has no single per-frame cost — its number caps out near a
     * full frame and wobbles as the work bleeds across frames. */
    while ((gba->timing.globalCycles - start_gc) < (uint64_t)frame_c
           && ++guard < max_iters) {
        int was_halted = gba->cpu->halted;
        int32_t before = gba->cpu->cycles;
        core->step(core);
        int32_t delta = gba->cpu->cycles - before;
        if (!was_halted && delta > 0)
            busy += delta;
    }
    return LL2NUM(busy);
}

#ifdef GEMBA_CORE_RCHEEVOS
/* --------------------------------------------------------- */
/* GembaCore::RARuntime — thin wrapper around rc_runtime_t   */
/*                    (RetroAchievements/rcheevos)           */
/*                                                           */
/* Compiled in only when GEMBA_CORE_RCHEEVOS is defined and  */
/* the rcheevos sources are on the compile line. Off by      */
/* default so a plain dev build needs nothing but libmgba.   */
/* --------------------------------------------------------- */

/* Achievement IDs arrive from Ruby as numeric strings ("12345").
 * rcheevos uses uint32_t internally.  ra_id_to_u32 parses them;
 * ra_id_to_str converts back for the do_frame return array. */
static uint32_t
ra_id_to_u32(VALUE rb_id)
{
    Check_Type(rb_id, T_STRING);
    return (uint32_t)strtoul(StringValueCStr(rb_id), NULL, 10);
}

/* GBA RA-address-space → mGBA bus address.
 *   0x000000–0x07FFFF → IWRAM  0x03000000
 *   0x080000+         → EWRAM  0x02000000 + (addr - 0x080000)
 * rcheevos passes raw RA addresses to the peek callback. */
static inline uint32_t
ra_to_gba_addr(uint32_t ra_addr)
{
    if (ra_addr < 0x08000)
        return 0x03000000 + ra_addr;
    else
        return 0x02000000 + (ra_addr - 0x08000);
}

/* rcheevos peek callback — called by rc_runtime_do_frame for every
 * memory read.  Translates RA addresses to GBA bus addresses and
 * reads 1, 2, or 4 bytes in little-endian order. */
static uint32_t
ra_peek(uint32_t ra_addr, uint32_t num_bytes, void *ud)
{
    struct mCore *core = (struct mCore *)ud;
    uint32_t gba = ra_to_gba_addr(ra_addr);
    switch (num_bytes) {
    case 1: return (uint32_t)core->busRead8(core,  gba);
    case 2: return (uint32_t)core->busRead16(core, gba);
    case 4: return           core->busRead32(core, gba);
    default: return 0;
    }
}

/* Triggered-ID collection for do_frame.
 * rc_runtime_event_handler_t has no userdata parameter, so we stash
 * a pointer to frame-local storage in a static before each call and
 * clear it after.  Ruby's GVL ensures single-threaded execution here. */
typedef struct {
    uint32_t ids[256];
    int      count;
} ra_frame_ctx_t;

static ra_frame_ctx_t *s_ra_frame_ctx = NULL;

static void
ra_event_handler(const rc_runtime_event_t *event)
{
    if (!s_ra_frame_ctx) return;
    if (event->type == RC_RUNTIME_EVENT_ACHIEVEMENT_TRIGGERED &&
        s_ra_frame_ctx->count < 256)
        s_ra_frame_ctx->ids[s_ra_frame_ctx->count++] = event->id;
}

/* Wrapper struct — embeds rc_runtime_t by value so a single allocation
 * covers both our bookkeeping and the rcheevos runtime internals. */
typedef struct {
    rc_runtime_t rc;
    int          count; /* number of currently activated achievements */
} ra_wrapper_t;

static void
ra_wrapper_free(void *ptr)
{
    ra_wrapper_t *w = (ra_wrapper_t *)ptr;
    rc_runtime_destroy(&w->rc);
    xfree(w);
}

static VALUE cRARuntime;

static const rb_data_type_t ra_runtime_type = {
    .wrap_struct_name = "GembaCore::RARuntime",
    .function = {
        .dmark = NULL,
        .dfree = ra_wrapper_free,
        .dsize = NULL,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE
ra_runtime_alloc(VALUE klass)
{
    ra_wrapper_t *w = ALLOC(ra_wrapper_t);
    rc_runtime_init(&w->rc);
    w->count = 0;
    return TypedData_Wrap_Struct(klass, &ra_runtime_type, w);
}

static ra_wrapper_t *
get_ra_wrapper(VALUE self)
{
    ra_wrapper_t *w;
    TypedData_Get_Struct(self, ra_wrapper_t, &ra_runtime_type, w);
    return w;
}

/*
 * RARuntime#activate(id, memaddr) → nil
 * Parse memaddr and register the achievement in the rcheevos runtime.
 * Raises ArgumentError if rcheevos rejects the condition string.
 */
static VALUE
ra_runtime_rb_activate(VALUE self, VALUE rb_id, VALUE rb_memaddr)
{
    Check_Type(rb_memaddr, T_STRING);
    ra_wrapper_t *w  = get_ra_wrapper(self);
    uint32_t      id = ra_id_to_u32(rb_id);
    int rc = rc_runtime_activate_achievement(&w->rc, id,
                                             StringValueCStr(rb_memaddr),
                                             NULL, 0);
    if (rc != RC_OK)
        rb_raise(rb_eArgError,
                 "RARuntime: rcheevos rejected memaddr (err %d): %s",
                 rc, StringValueCStr(rb_memaddr));
    w->count++;
    return Qnil;
}

/*
 * RARuntime#deactivate(id) → nil
 */
static VALUE
ra_runtime_rb_deactivate(VALUE self, VALUE rb_id)
{
    ra_wrapper_t *w = get_ra_wrapper(self);
    rc_runtime_deactivate_achievement(&w->rc, ra_id_to_u32(rb_id));
    if (w->count > 0) w->count--;
    return Qnil;
}

/*
 * RARuntime#reset_all → nil
 * Reset every achievement to WAITING state (as if freshly activated).
 * Call this after loading a save state so delta/prior histories are
 * discarded and achievements can't fire spuriously.
 */
static VALUE
ra_runtime_rb_reset_all(VALUE self)
{
    rc_runtime_reset(&get_ra_wrapper(self)->rc);
    return Qnil;
}

/*
 * RARuntime#clear → nil
 * Destroy all achievements and reinitialise the runtime from scratch.
 */
static VALUE
ra_runtime_rb_clear(VALUE self)
{
    ra_wrapper_t *w = get_ra_wrapper(self);
    rc_runtime_destroy(&w->rc);
    rc_runtime_init(&w->rc);
    w->count = 0;
    return Qnil;
}

/*
 * RARuntime#do_frame(core) → Array<String>
 * Evaluate all active achievements against current emulator memory.
 * Returns an array of string IDs for achievements that triggered.
 */
static VALUE
ra_runtime_rb_do_frame(VALUE self, VALUE rb_core)
{
    struct mgba_core *mc;
    TypedData_Get_Struct(rb_core, struct mgba_core, &mgba_core_type, mc);
    if (mc->destroyed || !mc->core)
        rb_raise(rb_eRuntimeError, "mGBA core has been destroyed");

    ra_wrapper_t    *w   = get_ra_wrapper(self);
    ra_frame_ctx_t   ctx = { .count = 0 };

    s_ra_frame_ctx = &ctx;
    rc_runtime_do_frame(&w->rc, ra_event_handler, ra_peek, mc->core, NULL);
    s_ra_frame_ctx = NULL;

    if (ctx.count == 0) return ra_empty_array;

    VALUE result = rb_ary_new_capa(ctx.count);
    char  buf[16];
    for (int i = 0; i < ctx.count; i++) {
        snprintf(buf, sizeof(buf), "%u", ctx.ids[i]);
        rb_ary_push(result, rb_str_new_cstr(buf));
    }
    return result;
}

/*
 * RARuntime#count → Integer
 * Number of currently activated achievements.
 */
static VALUE
ra_runtime_rb_count(VALUE self)
{
    return INT2NUM(get_ra_wrapper(self)->count);
}

/*
 * RARuntime#activate_richpresence(script) → true | false
 * Load a Rich Presence script into the runtime.
 * Returns true on success, false if the script failed to parse.
 */
static VALUE
ra_runtime_rb_activate_richpresence(VALUE self, VALUE rb_script)
{
    ra_wrapper_t *w = get_ra_wrapper(self);
    const char   *script = StringValueCStr(rb_script);
    int           rc;

    rc = rc_runtime_activate_richpresence(&w->rc, script, NULL, 0);
    return rc == RC_OK ? Qtrue : Qfalse;
}

/*
 * RARuntime#get_richpresence(core) → String | nil
 * Evaluate the active Rich Presence script against current memory and
 * return the display string, or nil if no script is loaded / empty result.
 */
static VALUE
ra_runtime_rb_get_richpresence(VALUE self, VALUE rb_core)
{
    ra_wrapper_t    *w = get_ra_wrapper(self);
    struct mgba_core *mc;
    char             buf[512];
    int              len;

    TypedData_Get_Struct(rb_core, struct mgba_core, &mgba_core_type, mc);
    len = rc_runtime_get_richpresence(&w->rc, buf, sizeof(buf), ra_peek, mc->core, NULL);
    if (len <= 0)
        return Qnil;
    return rb_str_new(buf, len);
}
#endif /* GEMBA_CORE_RCHEEVOS */

/* --------------------------------------------------------- */
/* Core#load_bios(path)                                      */
/* Load a BIOS file from path. Must be called before reset.  */
/* Returns true on success, false on failure.                */
/* --------------------------------------------------------- */

static VALUE
mgba_core_load_bios(VALUE self, VALUE rb_path)
{
    struct mgba_core *mc = get_mgba_core(self);
    Check_Type(rb_path, T_STRING);
    const char *path = StringValueCStr(rb_path);

    struct VFile *vf = VFileOpen(path, O_RDONLY);
    if (!vf) {
        return Qfalse;
    }

    bool ok = mc->core->loadBIOS(mc->core, vf, 0);
    if (!ok) {
        vf->close(vf);
    }
    /* mGBA takes ownership of vf on success; do not close */
    return ok ? Qtrue : Qfalse;
}

/* --------------------------------------------------------- */
/* GembaCore.gba_bios_checksum(bytes)                        */
/* Compute GBA BIOS checksum (mGBA algorithm) on raw bytes.  */
/* --------------------------------------------------------- */

static VALUE
mgba_gba_bios_checksum(VALUE self, VALUE rb_bytes)
{
    Check_Type(rb_bytes, T_STRING);
    long len = RSTRING_LEN(rb_bytes);
    uint32_t result = GBAChecksum((uint32_t *)RSTRING_PTR(rb_bytes), (size_t)(len / 4));
    return UINT2NUM(result);
}

void
Init_gemba_core_ext(void)
{
    /* Install no-op logger before any mGBA calls */
    mLogSetDefaultLogger(&s_null_logger);

    /* GembaCore module */
    mGembaCore = rb_define_module("GembaCore");

    /* GembaCore::Core class */
    cCore = rb_define_class_under(mGembaCore, "Core", rb_cObject);
    rb_define_alloc_func(cCore, mgba_core_alloc);

    rb_define_method(cCore, "initialize",  mgba_core_initialize, -1);
    rb_define_method(cCore, "run_frame",   mgba_core_run_frame, 0);
    rb_define_method(cCore, "video_buffer", mgba_core_video_buffer, 0);
    rb_define_method(cCore, "video_buffer_argb", mgba_core_video_buffer_argb, 0);
    rb_define_method(cCore, "audio_buffer", mgba_core_audio_buffer, 0);
    rb_define_method(cCore, "set_keys",    mgba_core_set_keys, 1);
    rb_define_method(cCore, "width",       mgba_core_width, 0);
    rb_define_method(cCore, "height",      mgba_core_height, 0);
    rb_define_method(cCore, "title",       mgba_core_title, 0);
    rb_define_method(cCore, "game_code",   mgba_core_game_code, 0);
    rb_define_method(cCore, "maker_code",  mgba_core_maker_code, 0);
    rb_define_method(cCore, "checksum",    mgba_core_checksum, 0);
    rb_define_method(cCore, "platform",    mgba_core_platform, 0);
    rb_define_method(cCore, "rom_size",    mgba_core_rom_size, 0);
    rb_define_method(cCore, "save_state_to_file", mgba_core_save_state_to_file, 1);
    rb_define_method(cCore, "load_state_from_file", mgba_core_load_state_from_file, 1);
    rb_define_method(cCore, "color_correction=", mgba_core_set_color_correction, 1);
    rb_define_method(cCore, "color_correction?", mgba_core_color_correction_p, 0);
    rb_define_method(cCore, "frame_blending=", mgba_core_set_frame_blending, 1);
    rb_define_method(cCore, "frame_blending?", mgba_core_frame_blending_p, 0);
    rb_define_method(cCore, "rewind_init",   mgba_core_rewind_init, 1);
    rb_define_method(cCore, "rewind_deinit", mgba_core_rewind_deinit, 0);
    rb_define_method(cCore, "rewind_push",   mgba_core_rewind_push, 0);
    rb_define_method(cCore, "rewind_pop",    mgba_core_rewind_pop, 0);
    rb_define_method(cCore, "rewind_count",  mgba_core_rewind_count, 0);
    rb_define_method(cCore, "destroy",     mgba_core_destroy, 0);
    rb_define_method(cCore, "destroyed?",  mgba_core_destroyed_p, 0);
    rb_define_method(cCore, "load_bios",    mgba_core_load_bios, 1);
    rb_define_method(cCore, "bios_loaded?", mgba_core_bios_loaded_p, 0);
    rb_define_method(cCore, "bus_read8",    mgba_core_bus_read8, 1);
    rb_define_method(cCore, "bus_read16",   mgba_core_bus_read16, 1);
    rb_define_method(cCore, "bus_read32",   mgba_core_bus_read32, 1);
    rb_define_method(cCore, "step",          mgba_core_step, 0);
    rb_define_method(cCore, "global_cycles", mgba_core_global_cycles, 0);
    rb_define_method(cCore, "frame_cycles",  mgba_core_frame_cycles, 0);
    rb_define_method(cCore, "cpu_cycles",    mgba_core_cpu_cycles, 0);
    rb_define_method(cCore, "cpu_halted?",   mgba_core_cpu_halted_p, 0);
    rb_define_method(cCore, "measure_frame_busy_cycles", mgba_core_measure_frame_busy_cycles, 0);

    /* BIOS checksum utility */
    rb_define_module_function(mGembaCore, "gba_bios_checksum", mgba_gba_bios_checksum, 1);
    rb_define_const(mGembaCore, "GBA_BIOS_CHECKSUM",    UINT2NUM(GBA_BIOS_CHECKSUM));
    rb_define_const(mGembaCore, "GBA_DS_BIOS_CHECKSUM", UINT2NUM(GBA_DS_BIOS_CHECKSUM));

    /* GBA key constants (bitmask values for set_keys) */
    rb_define_const(mGembaCore, "KEY_A",      INT2NUM(1 << GEMBA_KEY_A));
    rb_define_const(mGembaCore, "KEY_B",      INT2NUM(1 << GEMBA_KEY_B));
    rb_define_const(mGembaCore, "KEY_SELECT", INT2NUM(1 << GEMBA_KEY_SELECT));
    rb_define_const(mGembaCore, "KEY_START",  INT2NUM(1 << GEMBA_KEY_START));
    rb_define_const(mGembaCore, "KEY_RIGHT",  INT2NUM(1 << GEMBA_KEY_RIGHT));
    rb_define_const(mGembaCore, "KEY_LEFT",   INT2NUM(1 << GEMBA_KEY_LEFT));
    rb_define_const(mGembaCore, "KEY_UP",     INT2NUM(1 << GEMBA_KEY_UP));
    rb_define_const(mGembaCore, "KEY_DOWN",   INT2NUM(1 << GEMBA_KEY_DOWN));
    rb_define_const(mGembaCore, "KEY_R",      INT2NUM(1 << GEMBA_KEY_R));
    rb_define_const(mGembaCore, "KEY_L",      INT2NUM(1 << GEMBA_KEY_L));

    /* GBA button name → bitmask hash */
    VALUE btn_bits = rb_hash_new();
    rb_hash_aset(btn_bits, ID2SYM(rb_intern("a")),      INT2NUM(1 << GEMBA_KEY_A));
    rb_hash_aset(btn_bits, ID2SYM(rb_intern("b")),      INT2NUM(1 << GEMBA_KEY_B));
    rb_hash_aset(btn_bits, ID2SYM(rb_intern("l")),      INT2NUM(1 << GEMBA_KEY_L));
    rb_hash_aset(btn_bits, ID2SYM(rb_intern("r")),      INT2NUM(1 << GEMBA_KEY_R));
    rb_hash_aset(btn_bits, ID2SYM(rb_intern("up")),     INT2NUM(1 << GEMBA_KEY_UP));
    rb_hash_aset(btn_bits, ID2SYM(rb_intern("down")),   INT2NUM(1 << GEMBA_KEY_DOWN));
    rb_hash_aset(btn_bits, ID2SYM(rb_intern("left")),   INT2NUM(1 << GEMBA_KEY_LEFT));
    rb_hash_aset(btn_bits, ID2SYM(rb_intern("right")),  INT2NUM(1 << GEMBA_KEY_RIGHT));
    rb_hash_aset(btn_bits, ID2SYM(rb_intern("start")),  INT2NUM(1 << GEMBA_KEY_START));
    rb_hash_aset(btn_bits, ID2SYM(rb_intern("select")), INT2NUM(1 << GEMBA_KEY_SELECT));
    OBJ_FREEZE(btn_bits);
    rb_define_const(mGembaCore, "GBA_BTN_BITS", btn_bits);

    /* XOR delta for frame-diff analysis */
    rb_define_module_function(mGembaCore, "xor_delta", mgba_xor_delta, 2);
    rb_define_module_function(mGembaCore, "count_changed_pixels", mgba_count_changed_pixels, 1);

#ifdef GEMBA_CORE_RCHEEVOS
    /* Frozen empty array returned by RARuntime#do_frame when nothing triggered */
    ra_empty_array = rb_ary_freeze(rb_ary_new_capa(0));
    rb_gc_register_mark_object(ra_empty_array);

    /* GembaCore::RARuntime — RA condition evaluator */
    cRARuntime = rb_define_class_under(mGembaCore, "RARuntime", rb_cObject);
    rb_define_alloc_func(cRARuntime, ra_runtime_alloc);
    rb_define_method(cRARuntime, "activate",              ra_runtime_rb_activate,              2);
    rb_define_method(cRARuntime, "deactivate",            ra_runtime_rb_deactivate,            1);
    rb_define_method(cRARuntime, "reset_all",             ra_runtime_rb_reset_all,             0);
    rb_define_method(cRARuntime, "clear",                 ra_runtime_rb_clear,                 0);
    rb_define_method(cRARuntime, "do_frame",              ra_runtime_rb_do_frame,              1);
    rb_define_method(cRARuntime, "count",                 ra_runtime_rb_count,                 0);
    rb_define_method(cRARuntime, "activate_richpresence", ra_runtime_rb_activate_richpresence, 1);
    rb_define_method(cRARuntime, "get_richpresence",      ra_runtime_rb_get_richpresence,      1);
#endif /* GEMBA_CORE_RCHEEVOS */
}

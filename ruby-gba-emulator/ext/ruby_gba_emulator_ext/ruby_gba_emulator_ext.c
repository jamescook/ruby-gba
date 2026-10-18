#include "ruby_gba_emulator_ext.h"
#ifdef RUBY_GBA_EMULATOR_RCHEEVOS
#include "rc_runtime.h"
#endif
#include <mgba/core/config.h>
#include <mgba/core/serialize.h>
#include <mgba/internal/gba/serialize.h>
#include <mgba/internal/gb/gb.h>
#include <mgba/internal/sm83/sm83.h>
#include <mgba-util/memory.h>
#include <ruby/thread.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <fcntl.h>

/*
 * ruby-gba-emulator — a headless libmgba binding for dev/test verification.
 *
 * It steps a ROM one frame at a time and hands back the video/audio buffers and
 * bus memory, with no SDL2 or Tk anywhere. The RetroAchievements (rcheevos)
 * evaluator is present but compiled out by default — build with
 * RUBY_GBA_EMULATOR_RCHEEVOS defined (and the rcheevos sources on the compile
 * line) to bring it back without touching this file.
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

VALUE mRubyGBAEmulator;
static VALUE cCore;
#ifdef RUBY_GBA_EMULATOR_RCHEEVOS
static VALUE ra_empty_array; /* frozen [] returned by do_frame when nothing triggered */
#endif

/* WHAT THE EMULATOR SAID WHILE THE GAME RAN.
 *
 * mGBA reports a bad read, an unmapped address or a register it does not implement as a log
 * line. Those are exactly the things that leave a test staring at a blank screen with no
 * idea why, so they are kept rather than dropped — the quiet ones (info, debug, and the
 * "not implemented yet" notes) still are, or a normal run would bury the real complaint.
 *
 * mGBA's logger is set for the whole process, not per cartridge, so there is nowhere to
 * hang this but a file-level pointer to whichever core is running. One core at a time is
 * what this binding is for; a second one running at the same time would have its complaints
 * filed against the first.
 */
#define LOG_LINES 64
#define LOG_LINE_MAX 256
#define CHANGES_MAX 4096

/* One frame's worth of writes to the display. A background bent row by row writes the camera
 * on every one of 160 rows, a game's sprites are 512 halfwords and its colours another 512,
 * so a frame that sets everything up and bends as well comes to around 1,200. This is well
 * clear of that, and what goes past it is counted rather than dropped quietly. */
#define DISPLAY_WRITES_MAX 8192

static void recording_log(struct mLogger *, int, enum mLogLevel, const char *, va_list);

static struct mLogger s_recording_logger = {
    .log = recording_log,
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

struct display_recorder;

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
    /* What the core reported while it ran — see the callbacks below. */
    int ev_passes;             /* times the game read the pad: once a pass, for a game loop */
    int ev_crashed;            /* the core gave up on this cartridge */
    int log_count;             /* complaints kept */
    int log_dropped;           /* complaints past the cap */
    char log_lines[LOG_LINES][LOG_LINE_MAX];
    /* Watching an address change — see Core#watch. NULL until something is watched. */
    struct mDebugger *debugger;
    unsigned long arrivals;     /* times the program counter reached a watched routine */
    uint32_t arrival_address;   /* the instruction being counted */
    int counting_arrivals;      /* whether anything is being counted at all */
    int change_count;
    int change_dropped;
    struct watched_change {
        uint32_t address;
        uint32_t was;
        uint32_t now;
    } changes[CHANGES_MAX];
    /* Every write the game makes to the display — see Core#watch_display. NULL until asked
     * for, since it puts a shim in front of the renderer that costs a call per write. */
    struct display_recorder *display;
    /* The addresses a search has got down to — see Core#addresses_holding. One at a time. */
    struct mCoreMemorySearchResults *search;
    /* Where each word in recorded-sound channel A's queue came from — see Core#sound_feed_start.
     * Kept between feeds, so a feed read a frame at a time is one feed, for as long as nothing ran
     * unrecorded in between (+stopped_at+ says when the last feed stopped). */
    struct feed_queue_mirror {
        int known;                           /* whether this says anything at all yet */
        uint64_t stopped_at;                 /* the emulator's clock when the last feed stopped */
        uint32_t from[GBA_AUDIO_FIFO_SIZE];  /* each slot of the queue: the address its word came from */
        uint32_t word[GBA_AUDIO_FIFO_SIZE];  /* ...and the word, as it went in */
        uint32_t playing_from;               /* the word being played: where it came from, 0 unknown */
        uint32_t playing_word;               /* ...and the word, all four bytes */
    } feed_queue;
    /* What a feed saw, in the order it happened: a plain list, since it is written while a frame
     * runs with Ruby's lock released. */
    struct feed_log {
        int recording;                       /* between Core#sound_feed_start and #sound_feed_finish */
        int cut_short;                       /* the list could not grow, and things went unwritten */
        struct feed_event {
            uint64_t at;
            int line;
            int kind;                        /* a sample played, a word fetched, or silence (feed_event_kind) */
            uint32_t from;
            uint32_t value;                  /* the word, or the sample's byte */
            uint32_t late;                   /* how long after it was due the emulator got to it */
        } *events;
        size_t count;
        size_t room;
    } feed_log;
};

/* WHICH CARTRIDGE IS RUNNING RIGHT NOW, so the callbacks mGBA fires part-way through a
 * frame can find their way back to it. mGBA takes one logger for the whole process and
 * tells it nothing about who is running, so this has to be recorded on the way in.
 *
 * ONE PER THREAD, NOT ONE PER PROCESS, and that is what lets several cartridges run at
 * once. Each is set just before the frame and cleared just after, on the thread making
 * that call — so two cartridges running together each see their own, where a single
 * process-wide pointer meant the last one to start owned it and the other's warnings
 * landed in its log or were dropped.
 *
 * It cannot be Ruby's own per-Ractor storage: these callbacks run with Ruby's lock
 * released, which is the whole reason cartridges can overlap, and nothing may call into
 * Ruby from there. A thread-local costs a register and asks nothing of Ruby. */
#if defined(_MSC_VER)
#  define GEMBA_PER_THREAD __declspec(thread)
#else
#  define GEMBA_PER_THREAD __thread
#endif

static GEMBA_PER_THREAD struct mgba_core *s_logging_core = NULL;
static GEMBA_PER_THREAD struct mgba_core *s_watching_core = NULL;

static void
install_core_callbacks(struct mgba_core *mc);

static void
display_recorder_free(struct mgba_core *mc);

static void
search_free(struct mgba_core *mc);

static void
recording_log(struct mLogger *logger, int category, enum mLogLevel level,
              const char *format, va_list args)
{
    struct mgba_core *mc = s_logging_core;
    const char *name;
    char *slot;
    int used;

    (void)logger;
    if (!mc) return;
    if (!(level & (mLOG_FATAL | mLOG_ERROR | mLOG_WARN | mLOG_GAME_ERROR))) return;

    if (mc->log_count >= LOG_LINES) {
        mc->log_dropped++;
        return;
    }

    slot = mc->log_lines[mc->log_count];
    name = mLogCategoryName(category);
    used = snprintf(slot, LOG_LINE_MAX, "%s: ", name ? name : "?");
    if (used < 0) used = 0;
    if (used < LOG_LINE_MAX) {
        vsnprintf(slot + used, (size_t)(LOG_LINE_MAX - used), format, args);
    }
    mc->log_count++;
}

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
    display_recorder_free(mc);
    search_free(mc);
    free(mc->feed_log.events); /* a sound feed started and never finished */
    mc->feed_log.events = NULL;
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
    .wrap_struct_name = "RubyGBAEmulator::Core",
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
    mc->display = NULL;
    mc->search = NULL;
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

    /* Ask the core to report what happens while it runs, rather than working it out
     * afterwards from where the frame boundaries fell. */
    mc->core = core;
    install_core_callbacks(mc);

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
    struct mDebugger *debugger; /* non-NULL only while something is being watched */
};

static void *
run_frame_nogvl(void *arg)
{
    struct run_frame_args *a = arg;
    /* A cartridge being watched has to be driven through the debugger, since that is what
     * checks the watchpoints — see Core#watch. Everything else runs the plain way. */
    if (a->debugger) {
        mDebuggerRunFrame(a->debugger);
    } else {
        a->core->runFrame(a->core);
    }
    return NULL;
}

static void redraw_everything(struct mgba_core *mc);

/* Every frame draws every row, as the console does (see redraw_everything). */
static VALUE
mgba_core_run_frame(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    struct run_frame_args args = { .core = mc->core, .debugger = mc->debugger };
    redraw_everything(mc);
    s_logging_core = mc;
    if (mc->debugger) s_watching_core = mc;
    rb_thread_call_without_gvl(run_frame_nogvl, &args, RUBY_UBF_IO, NULL);
    s_logging_core = NULL;
    return Qnil;
}

/* ---------------------------------------------------------- */
/* WHAT THE CORE REPORTS WHILE A FRAME RUNS                    */
/*                                                             */
/* These fire inside mGBA, part-way through a frame, with      */
/* Ruby's lock released — so they cannot call into Ruby. They  */
/* only tally into the core's own struct, which Ruby reads     */
/* once the frame has returned.                                */
/*                                                             */
/* "Keys read" is the useful one: a game loop reads the pad    */
/* once a pass, so counting it is counting passes — which the  */
/* framework has otherwise had to do by adding a counter to    */
/* the cartridge and measuring a program nobody ships.         */
/* ---------------------------------------------------------- */

static void
ev_keys_read(void *context)
{
    struct mgba_core *mc = context;
    if (mc) mc->ev_passes++;
}

static void
ev_crashed(void *context)
{
    struct mgba_core *mc = context;
    if (mc) mc->ev_crashed = 1;
}

static void
install_core_callbacks(struct mgba_core *mc)
{
    struct mCoreCallbacks cbs;

    memset(&cbs, 0, sizeof(cbs));
    cbs.context     = mc;
    cbs.keysRead    = ev_keys_read;
    cbs.coreCrashed = ev_crashed;
    mc->core->addCoreCallbacks(mc->core, &cbs);
}

/* Core#pad_reads — how many times the game has read the pad since the cartridge was
 * loaded. A game loop reads it once a pass, at the START of one. */
static VALUE
mgba_core_pad_reads(VALUE self)
{
    return INT2NUM(get_mgba_core(self)->ev_passes);
}

/* Core#crashed? — did the core give up on this cartridge? */
static VALUE
mgba_core_crashed_p(VALUE self)
{
    return get_mgba_core(self)->ev_crashed ? Qtrue : Qfalse;
}

/* Core#complaints — what the emulator said about this cartridge, worst kinds only. */
static VALUE
mgba_core_complaints(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    VALUE out = rb_ary_new_capa(mc->log_count);
    int i;

    for (i = 0; i < mc->log_count; i++) {
        rb_ary_push(out, rb_str_new_cstr(mc->log_lines[i]));
    }
    if (mc->log_dropped > 0) {
        rb_ary_push(out, rb_sprintf("... and %d more", mc->log_dropped));
    }
    return out;
}

/* --------------------------------------------------------- */
/* Core#video_buffer                                         */
/* --------------------------------------------------------- */

/* The picture as XBGR8, four bytes a pixel, with the fourth byte of
 * every pixel zero.
 *
 * That byte is not colour and is not always empty: mGBA's software
 * renderer keeps its own notes there while it composes a line — which
 * layer drew the pixel, at what priority, whether it is a blend
 * target — and they are still there when the line is finished. Left
 * in, two pictures of exactly the same colours compare unequal because
 * one was drawn by a background and the other by a sprite. Cleared,
 * the bytes are the same exactly when the picture is. */
static VALUE
mgba_core_video_buffer(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    long npixels = (long)mc->width * mc->height;
    VALUE str = rb_str_new(NULL, npixels * (long)sizeof(uint32_t));
    uint32_t *dst = (uint32_t *)RSTRING_PTR(str);
    const uint32_t *src = (const uint32_t *)mc->video_buffer;

    for (long i = 0; i < npixels; i++)
        dst[i] = src[i] & 0x00FFFFFF;
    return str;
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

/* --------------------------------------------------------- */
/* Core#bus_read_bytes(address, count)                        */
/*                                                            */
/* A WHOLE STRETCH IN ONE ASK. A game's state is an area of   */
/* memory — a pool of sixty guards, a list, a map — and a     */
/* test that reads one a word at a time crosses into the      */
/* emulator once per four bytes. The crossing is the cost,    */
/* not the read: gathering the bytes here and handing back    */
/* one String makes it one crossing whatever the size.        */
/*                                                            */
/* Through the bus rather than straight out of the emulator's */
/* memory, so every address behaves the way the single reads  */
/* beside it do — mirrored regions, registers, and unmapped   */
/* addresses included.                                        */
/* --------------------------------------------------------- */

static VALUE
mgba_core_bus_read_bytes(VALUE self, VALUE addr, VALUE count)
{
    struct mgba_core *mc = get_mgba_core(self);
    uint32_t address = (uint32_t)NUM2UINT(addr);
    long wanted = NUM2LONG(count);
    VALUE out;
    uint8_t *bytes;
    long i;

    if (wanted <= 0) {
        rb_raise(rb_eArgError, "there is nothing to read: asked for %ld bytes", wanted);
    }
    out = rb_str_new(NULL, wanted);
    bytes = (uint8_t *)RSTRING_PTR(out);
    for (i = 0; i < wanted; i++) {
        bytes[i] = (uint8_t)mc->core->busRead8(mc->core, address + (uint32_t)i);
    }
    return out;
}

/* Core#bus_write32(address, value)                          */
/* Write four bytes (little-endian) to the GBA address bus.  */
/*                                                           */
/* This is how a running game is put into a state it would   */
/* otherwise have to be PLAYED into. Set the variable that   */
/* holds which scene is running and the next frame is that   */
/* scene, with no rebuild and nobody pressing START — which  */
/* is what lets the build measure the part of a game a       */
/* player would have to reach.                               */
/* --------------------------------------------------------- */

static VALUE
mgba_core_bus_write32(VALUE self, VALUE addr, VALUE value)
{
    struct mgba_core *mc = get_mgba_core(self);
    mc->core->busWrite32(mc->core, (uint32_t)NUM2UINT(addr), (uint32_t)NUM2UINT(value));
    return Qnil;
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
    mc->feed_queue.known = 0; /* the sound queue is the state's now, and nothing says where its words came from */
    return ok ? Qtrue : Qfalse;
}

/* --------------------------------------------------------- */
/* Core#state_file_identity(path)                            */
/* Which cartridge a save state was taken from, WITHOUT      */
/* loading it. Returns {rom_crc32:, title:} or nil.          */
/*                                                           */
/* A state is a snapshot of the console's registers and RAM, */
/* and every address in it belongs to the exact cartridge it */
/* was taken from. Load one into a cartridge built even a    */
/* moment later and the addresses point at whatever has      */
/* moved into those places — which still reads as numbers,   */
/* and so measures rubbish quietly. mGBA itself only refuses */
/* a state from a different GAME (a different title in the   */
/* header); it accepts one from a different BUILD of the     */
/* same game, which is the case that happens constantly      */
/* while a game is being written. So the caller needs the    */
/* identity to compare itself.                               */
/*                                                           */
/* The file is a PNG with the state in its chunks, so        */
/* mCoreExtractState is asked to unwrap it rather than this  */
/* parsing a format it does not own.                         */
/* --------------------------------------------------------- */

static VALUE
mgba_core_state_file_identity(VALUE self, VALUE rb_path)
{
    struct mgba_core *mc = get_mgba_core(self);
    Check_Type(rb_path, T_STRING);
    const char *path = StringValueCStr(rb_path);

    struct VFile *vf = VFileOpen(path, O_RDONLY);
    if (!vf) {
        return Qnil;
    }

    void *raw = mCoreExtractState(mc->core, vf, NULL);
    vf->close(vf);
    if (!raw) {
        return Qnil;
    }

    /* The serialized fields are little-endian, which is a plain read on every
     * host this builds on. */
    struct GBASerializedState *state = (struct GBASerializedState *)raw;
    VALUE out = rb_hash_new();
    rb_hash_aset(out, ID2SYM(rb_intern("rom_crc32")), UINT2NUM(state->romCrc32));
    rb_hash_aset(out, ID2SYM(rb_intern("title")),
                 rb_str_new(state->title, strnlen(state->title, sizeof(state->title))));
    mappedMemoryFree(raw, mc->core->stateSize(mc->core));
    return out;
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
/*                                                            */
/* A ring of whole save states: push one per frame, and pop   */
/* to go back to the oldest one the ring still holds. It is   */
/* reached from Ruby as Core#rewind_init / _push / _pop /     */
/* _count, and ruby-gba does not call any of them — the probe */
/* has no wrapper over them and nothing in the framework asks */
/* for one. It is here for a caller that wants to step back   */
/* through a run, which is a thing a game's own tests want    */
/* long before this framework does.                           */
/*                                                            */
/* WHAT IT DOES IS JUMP, NOT STEP. The pop loads the OLDEST   */
/* state held and empties the ring, so it goes back to the    */
/* far end of the history rather than a frame. Going back one */
/* frame at a time wants mGBA's own rewind (core/rewind.h),   */
/* which stores the difference between one state and the next */
/* and can be asked for any point in between.                 */
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
 * RubyGBAEmulator.xor_delta(current, previous) → String
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
 * RubyGBAEmulator.count_changed_pixels(delta) → Integer
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
/* Screen: questions about a whole picture                   */
/* --------------------------------------------------------- */

/* WHY THESE ARE HERE AND NOT IN RUBY. A screen is 38,400 pixels, and a
 * test that asks something of the whole of it on every frame goes
 * through every one of them. In Ruby that is a number made and thrown
 * away for every pixel, which is far more work than running the frame
 * was; here it is one pass over the bytes.
 *
 * A SCREEN is what Core#video_buffer hands over: four bytes a pixel,
 * red, green, blue and a byte of nothing. Each function takes that
 * string, so it answers for the screen a core is showing now and just
 * the same for one somebody kept from earlier. It is NOT the string
 * `colors` hands back, which is two bytes a pixel: nothing here can
 * tell the two apart by looking, so a caller has to.
 *
 * FIVE BITS A CHANNEL. A console has thirty-two levels of each of red,
 * green and blue, and that is the precision every answer here is
 * given at: the top five bits of each of mGBA's eight. What mGBA
 * holds below them is its own working — it fills a palette colour's
 * low bits in one way, and works a colour the display brightened,
 * darkened or mixed out at eight bits, so the same five-bit colour
 * can be two different bytes. Two screens of the same bytes are one
 * picture; two of different bytes may still be.
 *
 * `only_color` and `brightness` can be asked at all eight bits instead,
 * for a caller that was reading mGBA's own numbers and has to go on
 * getting the answers it got. */
#define SCREEN_BYTES_PER_PIXEL 4
#define SCREEN_BITS_SHOWN 0x00F8F8F8u
#define SCREEN_BITS_HELD 0x00FFFFFFu

/* One pixel out of a screen. Copied out rather than read through a
 * cast, because nothing promises a Ruby string starts where a 32-bit
 * number is allowed to. */
static inline uint32_t
screen_pixel(const unsigned char *screen, long at)
{
    uint32_t px;
    memcpy(&px, screen + at * SCREEN_BYTES_PER_PIXEL, sizeof(px));
    return px;
}

/* The console's own 15-bit colour for one of mGBA's pixels: red in the
 * low five bits, then green, then blue. */
static inline uint32_t
screen_console_color(uint32_t px)
{
    return ((px >> 3) & 0x001F) | ((px >> 6) & 0x03E0) | ((px >> 9) & 0x7C00);
}

/* How many pixels +screen+ holds. Raises for a string that is not a
 * whole number of them, which is some other bytes handed over where a
 * screen was meant. It is all that can be checked: a string that IS a
 * whole number of pixels is taken for a screen. */
static long
screen_pixel_count(VALUE screen)
{
    long len = RSTRING_LEN(screen);
    if (len % SCREEN_BYTES_PER_PIXEL != 0)
        rb_raise(rb_eArgError,
                 "A screen holds %d bytes for each pixel. This one holds %ld bytes, "
                 "which is not a whole number of pixels. Give the screen as the "
                 "emulator hands it over (`frame_buffer`).",
                 SCREEN_BYTES_PER_PIXEL, len);
    return len / SCREEN_BYTES_PER_PIXEL;
}

/* How many bits of each channel a question looks at: 5, which is what
 * a console shows and what is asked with nothing said, or 8, which is
 * everything mGBA holds. */
static int
screen_bits(VALUE bits)
{
    if (NIL_P(bits)) return 5;

    long given = NUM2LONG(bits);
    if (given != 5 && given != 8)
        rb_raise(rb_eArgError,
                 "The bits of a channel must be 5 or 8. They were %ld. Give 5 for the "
                 "colours a console shows, or 8 for the colours as the emulator holds them.",
                 given);
    return (int)given;
}

/*
 * RubyGBAEmulator::Screen.colors(screen) → String
 *
 * The screen as the console's own 15-bit colours, two bytes a pixel,
 * low byte first, a row at a time from the top. It is what to keep a
 * still as, or to hash one: half the size of the screen, and the same
 * bytes for the same picture whatever mGBA held below five bits. So
 * two of these are compared with `==`, and they are not screens: the
 * other questions here do not take them.
 */
static VALUE
screen_colors(VALUE mod, VALUE screen)
{
    (void)mod;
    StringValue(screen);

    long count = screen_pixel_count(screen);
    VALUE colors = rb_str_new(NULL, count * 2);
    const unsigned char *src = (const unsigned char *)RSTRING_PTR(screen);
    unsigned char *dst = (unsigned char *)RSTRING_PTR(colors);

    for (long i = 0; i < count; i++) {
        uint32_t color = screen_console_color(screen_pixel(src, i));
        dst[i * 2] = (unsigned char)(color & 0xFF);
        dst[i * 2 + 1] = (unsigned char)(color >> 8);
    }

    return colors;
}

/*
 * RubyGBAEmulator::Screen.color_list(screen) → Array of Integer
 *
 * The same colours as numbers, one for each pixel, a row at a time from
 * the top: what `colors(screen).unpack("v*")` gives, made here because
 * unpacking is most of what a list of 38,400 numbers costs. A list is
 * for looking pixels up in, or counting them; to keep a screen or to
 * compare two, the string is a fraction of the size and of the time.
 */
static VALUE
screen_color_list(VALUE mod, VALUE screen)
{
    (void)mod;
    StringValue(screen);

    long count = screen_pixel_count(screen);
    VALUE list = rb_ary_new_capa(count);
    const unsigned char *src = (const unsigned char *)RSTRING_PTR(screen);

    /* Every colour is a small number, which Ruby keeps without making
     * an object, and the list already has room: nothing in this loop
     * can make an object, so the screen stays where it is. */
    for (long i = 0; i < count; i++)
        rb_ary_push(list, INT2FIX((int)screen_console_color(screen_pixel(src, i))));

    RB_GC_GUARD(screen);
    return list;
}

/*
 * RubyGBAEmulator::Screen.only_color(screen, bits = 5) → Integer or nil
 *
 * The one colour every pixel of the screen is, or nil when the screen
 * holds more than one. A black screen answers 0, which is what "has it
 * faded all the way out" comes down to, and a white one 0x7FFF, which
 * is a flash at its brightest. A screen of no pixels has no colour and
 * answers nil.
 *
 * At five bits the answer is the console's 15-bit colour. At eight it
 * is the number mGBA holds, red in the low byte, then green, then
 * blue — so white is 0xFFFFFF — and one pixel a single step out in
 * mGBA's own working is enough to answer nil. That is the finer
 * question, and "is the screen black" asked of it can be no while five
 * bits say yes: a pixel the display darkened to almost nothing.
 */
static VALUE
screen_only_color(int argc, VALUE *argv, VALUE mod)
{
    (void)mod;
    VALUE screen, bits_value;
    rb_scan_args(argc, argv, "11", &screen, &bits_value);
    StringValue(screen);
    int bits = screen_bits(bits_value);

    long count = screen_pixel_count(screen);
    if (count == 0) return Qnil;

    const unsigned char *src = (const unsigned char *)RSTRING_PTR(screen);
    uint32_t looked_at = bits == 5 ? SCREEN_BITS_SHOWN : SCREEN_BITS_HELD;
    uint32_t first = screen_pixel(src, 0);

    for (long i = 1; i < count; i++) {
        if ((screen_pixel(src, i) ^ first) & looked_at) return Qnil;
    }

    return UINT2NUM(bits == 5 ? screen_console_color(first) : first & SCREEN_BITS_HELD);
}

/* How many pixels each of two screens holds, for a question asked of
 * both. Raises unless they hold the same number: a screen beside one
 * of another size is a mistake, and answering "not the same" for it
 * would hide the mistake behind a plausible answer. */
static long
screen_pair_pixel_count(VALUE one, VALUE other)
{
    long count = screen_pixel_count(one);
    long other_count = screen_pixel_count(other);
    if (count != other_count)
        rb_raise(rb_eArgError,
                 "Two screens must hold the same number of pixels to be compared. "
                 "These hold %ld and %ld. Give two screens as the emulator hands them "
                 "over (`frame_buffer`), from cartridges of one kind of console.",
                 count, other_count);
    return count;
}

/*
 * RubyGBAEmulator::Screen.same?(one, other) → true or false
 *
 * Whether two screens are the same picture at the precision a console
 * shows: every pixel the same five bits of red, of green and of blue.
 * Two screens of the same bytes are known to be in one comparison of
 * the bytes, which is nearly every frame of two cartridges that agree;
 * only two that are different bytes are gone through a pixel at a time.
 * (The same question at eight bits is `==` on the two strings.)
 */
static VALUE
screen_same_p(VALUE mod, VALUE one, VALUE other)
{
    (void)mod;
    StringValue(one);
    StringValue(other);

    long count = screen_pair_pixel_count(one, other);
    const unsigned char *a = (const unsigned char *)RSTRING_PTR(one);
    const unsigned char *b = (const unsigned char *)RSTRING_PTR(other);

    if (memcmp(a, b, (size_t)count * SCREEN_BYTES_PER_PIXEL) == 0) return Qtrue;

    for (long i = 0; i < count; i++) {
        if ((screen_pixel(a, i) ^ screen_pixel(b, i)) & SCREEN_BITS_SHOWN) return Qfalse;
    }

    return Qtrue;
}

/*
 * RubyGBAEmulator::Screen.difference(one, other, width, looked_at = nil) → Hash or nil
 *
 * How two screens differ, at the precision a console shows, or nil
 * when they are one picture:
 *
 *   { count: 12,              # how many pixels differ
 *     box: [96, 40, 8, 6],    # the part of the screen they all lie in: x, y, width, height
 *     at: [96, 40],           # the first of them, a row at a time from the top
 *     colors: [0x7C00, 0] }   # that pixel's colour on the one screen and on the other
 *
 * +width+ is how many pixels make a row, which the bytes do not say.
 * All that can be checked of it is that the screen is whole rows that
 * wide, so a wrong width that happens to divide gives a wrong box.
 *
 * +looked_at+ leaves part of the screen out: a string of one byte for
 * each pixel, nought for a pixel that is not looked at. A pixel left
 * out is not counted, is not in the box and is never the first, so a
 * difference wholly inside what is left out is no difference. It is
 * for a part of a picture known to differ — a clock, a status bar that
 * is not drawn yet — which would otherwise be every answer.
 */
static VALUE
screen_difference(int argc, VALUE *argv, VALUE mod)
{
    (void)mod;
    VALUE one, other, width_value, looked_at;
    rb_scan_args(argc, argv, "31", &one, &other, &width_value, &looked_at);

    /* Everything is turned into what is read here BEFORE anything is
     * measured. Turning a value into a string or a number can run the
     * caller's own code, and that code can change a screen already
     * measured — after which the lengths below would be of a screen
     * that is no longer there. */
    StringValue(one);
    StringValue(other);
    long width = NUM2LONG(width_value);
    if (!NIL_P(looked_at)) StringValue(looked_at);

    long count = screen_pair_pixel_count(one, other);
    if (width <= 0 || count % width != 0)
        rb_raise(rb_eArgError,
                 "The width must be how many pixels are in one row of the screen. It was "
                 "%ld, and these screens hold %ld pixels, which is not a whole number of "
                 "rows that wide. Give the width of the screen, which is 240 for a Game Boy Advance.",
                 width, count);

    const unsigned char *mask = NULL;
    if (!NIL_P(looked_at)) {
        if (RSTRING_LEN(looked_at) != count)
            rb_raise(rb_eArgError,
                     "What is looked at must hold one byte for each pixel. It holds %ld "
                     "bytes, and these screens hold %ld pixels. Give a string of %ld bytes: "
                     "0 for a pixel to leave out, and 1 for a pixel to look at.",
                     RSTRING_LEN(looked_at), count, count);
        mask = (const unsigned char *)RSTRING_PTR(looked_at);
    }

    const unsigned char *a = (const unsigned char *)RSTRING_PTR(one);
    const unsigned char *b = (const unsigned char *)RSTRING_PTR(other);
    long height = count / width;
    long differing = 0, first = -1;
    long left = width, right = -1, top = -1, bottom = -1;

    for (long y = 0; y < height; y++) {
        long row = y * width;
        /* A row of the same bytes holds no difference, which is most rows of most frames. */
        if (memcmp(a + row * SCREEN_BYTES_PER_PIXEL, b + row * SCREEN_BYTES_PER_PIXEL,
                   (size_t)width * SCREEN_BYTES_PER_PIXEL) == 0)
            continue;

        for (long x = 0; x < width; x++) {
            long at = row + x;
            if (mask && !mask[at]) continue;
            if (!((screen_pixel(a, at) ^ screen_pixel(b, at)) & SCREEN_BITS_SHOWN)) continue;

            differing++;
            if (first < 0) { first = at; top = y; }
            bottom = y;
            if (x < left) left = x;
            if (x > right) right = x;
        }
    }

    if (differing == 0) return Qnil;

    /* Read out of the two screens before anything is made, since making an object can
     * move a short string and these pointers with it. */
    uint32_t first_color = screen_console_color(screen_pixel(a, first));
    uint32_t first_other_color = screen_console_color(screen_pixel(b, first));

    VALUE difference = rb_hash_new();
    rb_hash_aset(difference, ID2SYM(rb_intern("count")), LONG2NUM(differing));
    rb_hash_aset(difference, ID2SYM(rb_intern("box")),
                 rb_ary_new_from_args(4, LONG2NUM(left), LONG2NUM(top),
                                      LONG2NUM(right - left + 1), LONG2NUM(bottom - top + 1)));
    rb_hash_aset(difference, ID2SYM(rb_intern("at")),
                 rb_ary_new_from_args(2, LONG2NUM(first % width), LONG2NUM(first / width)));
    rb_hash_aset(difference, ID2SYM(rb_intern("colors")),
                 rb_ary_new_from_args(2, UINT2NUM(first_color), UINT2NUM(first_other_color)));
    return difference;
}

/*
 * RubyGBAEmulator::Screen.brightness(screen) → Integer
 *
 * How bright the screen is: the red, green and blue of every pixel
 * added up. It is one number that rises and falls with a fade, which
 * is what watching one frame by frame wants, and it says nothing about
 * where the light is.
 *
 * At five bits each channel is the level a console shows, 0 to 31, so
 * a white screen is 93 for each pixel. At eight it is the number mGBA
 * holds, 0 to 255, and a white screen is 765 for each pixel. A black
 * screen is 0 either way, but a screen can reach 0 at five bits a
 * frame before it does at eight.
 */
static VALUE
screen_brightness(int argc, VALUE *argv, VALUE mod)
{
    (void)mod;
    VALUE screen, bits_value;
    rb_scan_args(argc, argv, "11", &screen, &bits_value);
    StringValue(screen);
    int bits = screen_bits(bits_value);

    long count = screen_pixel_count(screen);
    const unsigned char *src = (const unsigned char *)RSTRING_PTR(screen);
    unsigned long long total = 0;

    if (bits == 5) {
        for (long i = 0; i < count; i++) {
            uint32_t px = screen_pixel(src, i);
            total += ((px >> 3) & 0x1F) + ((px >> 11) & 0x1F) + ((px >> 19) & 0x1F);
        }
    } else {
        for (long i = 0; i < count; i++) {
            uint32_t px = screen_pixel(src, i);
            total += (px & 0xFF) + ((px >> 8) & 0xFF) + ((px >> 16) & 0xFF);
        }
    }

    return ULL2NUM(total);
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
/* Core#watch(address) / Core#changes                          */
/*                                                            */
/* BEING TOLD a value changed, rather than looking at it once  */
/* a frame and inferring the rest. Sampling cannot see a value */
/* that moved twice between looks, cannot say when inside the  */
/* frame it moved, and cannot say what it moved FROM. For      */
/* chasing "what is knocking the player's health down", those  */
/* are the whole question.                                    */
/*                                                            */
/* mGBA's own debugger does this. It attaches with no command  */
/* line and no thread of its own: make one of the CUSTOM kind, */
/* give it somewhere to report to, attach it, then hand it the */
/* address. It calls back on a change with both values.       */
/*                                                            */
/* IT IS NOT FREE. Every read and write the game makes goes    */
/* through the debugger's own memory handling for as long as   */
/* anything is watched, and frames have to be driven through   */
/* the debugger rather than the core. So nothing is attached   */
/* until something is actually watched, and a cartridge nobody */
/* asked about runs exactly as it did before.                 */
/* --------------------------------------------------------- */

/* The debugger has nowhere to hang a context of its own, so the core being watched is kept
 * in a file-level pointer (declared above) — the same one-at-a-time limitation the logger
 * has, and for the same reason. */
static void
watch_entered(struct mDebugger *debugger, enum mDebuggerEntryReason reason,
              struct mDebuggerEntryInfo *info)
{
    struct mgba_core *mc = s_watching_core;

    if (mc && reason == DEBUGGER_ENTER_BREAKPOINT) {
        mc->arrivals++;
    } else if (mc && reason == DEBUGGER_ENTER_WATCHPOINT && info) {
        if (mc->change_count < CHANGES_MAX) {
            struct watched_change *slot = &mc->changes[mc->change_count];
            slot->address = info->address;
            slot->was     = info->type.wp.oldValue;
            slot->now     = info->type.wp.newValue;
            mc->change_count++;
        } else {
            mc->change_dropped++;
        }
    }
    /* Carry on running: this is a report, not a place to stop. */
    debugger->state = DEBUGGER_RUNNING;
}

/* Attach the debugger if nothing has yet, so a watch and a breakpoint share the one. */
static void
attach_debugger(struct mgba_core *mc)
{
    if (mc->debugger) return;

    if (!mc->core->supportsDebuggerType(mc->core, DEBUGGER_CUSTOM)) {
        rb_raise(rb_eRuntimeError, "this core cannot be watched");
    }
    /* mGBA's own factory only builds the command-line and network debuggers — the
     * CUSTOM kind is the one a program drives itself, and it is expected to bring its
     * own. So this is a plain zeroed one with somewhere to report to; attaching fills
     * in the rest (the platform, the identity, the stack trace). */
    mc->debugger = calloc(1, sizeof(struct mDebugger));
    if (!mc->debugger) {
        rb_raise(rb_eNoMemError, "could not make a debugger to watch with");
    }
    mc->debugger->type    = DEBUGGER_CUSTOM;
    mc->debugger->entered = watch_entered;
    mDebuggerAttach(mc->debugger, mc->core);
    mc->debugger->state = DEBUGGER_RUNNING;
}

/* Core#watch_arrivals(address) — count every time the program reaches this instruction.
 *
 * The same debugger a watched address uses, with a breakpoint instead of a watchpoint. It is
 * a REPORT rather than a stop: the callback counts the arrival and sets the debugger running
 * again, so the cartridge never pauses.
 *
 * WHY THIS IS THE ONE HONEST WAY TO COUNT PASSES OF A GAME LOOP. The alternatives are a
 * proxy or a modified cartridge. The pad-read count is a proxy, and it reports nothing at all
 * for a loop that never asks for input. Adding a counter to the program means the cartridge
 * measured is not the cartridge that ships, and an extra instruction can tip a routine out of
 * the console's quick memory and change the timing being measured. An arrival at the loop's
 * own first instruction is the pass itself.
 *
 * Checking a breakpoint is done per instruction, which sounds ruinous and is not — measured
 * at a twelfth on a cartridge that sleeps most of the frame and a bit over a third on one
 * that uses all of it. Nothing is attached until something is counted.
 */
static VALUE
mgba_core_watch_arrivals(VALUE self, VALUE rb_address)
{
    struct mgba_core *mc = get_mgba_core(self);
    struct mBreakpoint bp;

    attach_debugger(mc);

    memset(&bp, 0, sizeof(bp));
    bp.address   = (uint32_t)NUM2ULONG(rb_address);
    bp.segment   = -1;
    bp.type      = BREAKPOINT_HARDWARE;
    bp.condition = NULL;

    s_watching_core = mc;
    if (mc->debugger->platform->setBreakpoint(mc->debugger->platform, &bp) < 0) {
        rb_raise(rb_eRuntimeError, "could not watch for arrivals at 0x%08X", (unsigned)bp.address);
    }
    /* Remembered here as well as in the debugger, because measuring what a frame COSTS walks
     * the cartridge a step at a time by its own route, which never asks the debugger anything.
     * That route counts arrivals itself — see measure_frame_split — so a caller can measure
     * the cost of a window and count its passes in the same run. */
    mc->arrival_address  = bp.address;
    mc->counting_arrivals = 1;
    return self;
}

/* Core#arrivals — how many times the watched instruction has been reached. */
static VALUE
mgba_core_arrivals(VALUE self)
{
    return ULONG2NUM(get_mgba_core(self)->arrivals);
}

/* Core#watch(address) — report every change to the word at this address. */
static VALUE
mgba_core_watch(VALUE self, VALUE rb_address)
{
    struct mgba_core *mc = get_mgba_core(self);
    struct mWatchpoint wp;

    attach_debugger(mc);

    memset(&wp, 0, sizeof(wp));
    wp.address   = (uint32_t)NUM2ULONG(rb_address);
    wp.segment   = -1;
    wp.type      = WATCHPOINT_WRITE_CHANGE; /* a write that leaves a different value */
    wp.condition = NULL;

    s_watching_core = mc;
    if (mc->debugger->platform->setWatchpoint(mc->debugger->platform, &wp) < 0) {
        rb_raise(rb_eRuntimeError, "could not watch 0x%08X", (unsigned)wp.address);
    }
    return self;
}

/* Core#changes_missed — changes that happened after the record filled up. A busy address
 * can move thousands of times a second, so the record is bounded; saying how many were lost
 * is what stops a truncated list reading like the whole story. */
static VALUE
mgba_core_changes_missed(VALUE self)
{
    return INT2NUM(get_mgba_core(self)->change_dropped);
}

/* Core#take_changes — the changes seen since the last time this was asked, oldest first,
 * and the record starts again. Drained once a frame, so the record only has to hold one
 * frame's worth rather than a whole run's. */
static VALUE
mgba_core_take_changes(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    VALUE out = rb_ary_new_capa(mc->change_count);
    int i;

    for (i = 0; i < mc->change_count; i++) {
        VALUE entry = rb_hash_new();
        rb_hash_aset(entry, ID2SYM(rb_intern("address")), ULONG2NUM(mc->changes[i].address));
        rb_hash_aset(entry, ID2SYM(rb_intern("was")),     ULONG2NUM(mc->changes[i].was));
        rb_hash_aset(entry, ID2SYM(rb_intern("now")),     ULONG2NUM(mc->changes[i].now));
        rb_ary_push(out, entry);
    }
    mc->change_count = 0;
    return out;
}

/* --------------------------------------------------------- */
/* Core#sprites — the objects the console is showing          */
/*                                                            */
/* The console keeps a table of 128 sprites and composes the  */
/* picture from it. Working backwards from the finished       */
/* picture cannot tell a hidden sprite from one drawn in the  */
/* backdrop colour, from one behind a background, or from one */
/* just off the edge — and a test asking "where is the ship"  */
/* wants the answer, not a pixel hunt. The table has it, and  */
/* the emulator hands it over.                                */
/*                                                            */
/* Only the ones actually being drawn are returned: an entry  */
/* the game has switched off is nothing to a test, and there  */
/* are always 128 entries whether the game uses them or not.  */
/* The bit layout is read with mGBA's own accessors, so which */
/* bit means what stays mGBA's business and not ours.         */
/* --------------------------------------------------------- */
static VALUE
mgba_core_sprites(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    struct GBA *gba;
    VALUE out;
    int i;

    if (mc->core->platform(mc->core) != mPLATFORM_GBA) {
        rb_raise(rb_eRuntimeError, "sprites is GBA-only");
    }
    gba = (struct GBA *)mc->core->board;
    out = rb_ary_new();

    for (i = 0; i < 128; i++) {
        struct GBAObj *obj = &gba->video.oam.obj[i];
        VALUE entry;

        /* A sprite that is not transformed and carries the disable bit is switched off.
         * The same bit means "draw me at double size" once a sprite is transformed, so
         * the two have to be told apart before it can be read. */
        if (!GBAObjAttributesAIsTransformed(obj->a) && GBAObjAttributesAIsDisable(obj->a)) {
            continue;
        }

        entry = rb_hash_new();
        rb_hash_aset(entry, ID2SYM(rb_intern("slot")),     INT2NUM(i));
        rb_hash_aset(entry, ID2SYM(rb_intern("x")),        INT2NUM(GBAObjAttributesBGetX(obj->b)));
        rb_hash_aset(entry, ID2SYM(rb_intern("y")),        INT2NUM(GBAObjAttributesAGetY(obj->a)));
        rb_hash_aset(entry, ID2SYM(rb_intern("tile")),     INT2NUM(GBAObjAttributesCGetTile(obj->c)));
        rb_hash_aset(entry, ID2SYM(rb_intern("palette")),  INT2NUM(GBAObjAttributesCGetPalette(obj->c)));
        /* HOW MANY COLOURS THIS PICTURE DRAWS FROM, which decides what the palette field
         * above means. A picture is stored one of two ways: half a byte a pixel, picking out
         * of a GROUP of sixteen colours, or a whole byte picking out of all 256. The palette
         * field names the group — and means nothing at all for a picture stored the other
         * way, where there is no group to name. Nothing else on the row says which, so
         * without this a reader handing over "the sixteen colours at that group" would be
         * right for most sprites and arbitrary for the rest, and would look the same either
         * way. */
        rb_hash_aset(entry, ID2SYM(rb_intern("color_count")),
                     INT2NUM(GBAObjAttributesAIs256Color(obj->a) ? 256 : 16));
        rb_hash_aset(entry, ID2SYM(rb_intern("priority")), INT2NUM(GBAObjAttributesCGetPriority(obj->c)));
        rb_hash_aset(entry, ID2SYM(rb_intern("shape")),    INT2NUM(GBAObjAttributesAGetShape(obj->a)));
        rb_hash_aset(entry, ID2SYM(rb_intern("size")),     INT2NUM(GBAObjAttributesBGetSize(obj->b)));
        rb_hash_aset(entry, ID2SYM(rb_intern("mirrored_across")),
                     GBAObjAttributesBIsHFlip(obj->b) ? Qtrue : Qfalse);
        rb_hash_aset(entry, ID2SYM(rb_intern("mirrored_down")),
                     GBAObjAttributesBIsVFlip(obj->b) ? Qtrue : Qfalse);
        rb_hash_aset(entry, ID2SYM(rb_intern("turned")),
                     GBAObjAttributesAIsTransformed(obj->a) ? Qtrue : Qfalse);
        rb_ary_push(out, entry);
    }
    return out;
}

/* --------------------------------------------------------- */
/* Core#palette — the colours the console is drawing from      */
/*                                                            */
/* 512 of them: the first 256 for the backgrounds, the rest    */
/* for the sprites, each a 15-bit colour. A game fades, tints  */
/* or recolours a character by changing these rather than by   */
/* redrawing anything, so a test asking "did the fade happen"  */
/* off the picture is really asking about these numbers — the  */
/* long way round, and confounded by everything else on        */
/* screen.                                                     */
/* --------------------------------------------------------- */
static VALUE
mgba_core_palette(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    struct GBA *gba;
    VALUE out;
    int i;

    if (mc->core->platform(mc->core) != mPLATFORM_GBA) {
        rb_raise(rb_eRuntimeError, "palette is GBA-only");
    }
    gba = (struct GBA *)mc->core->board;
    out = rb_ary_new_capa(512);
    for (i = 0; i < 512; i++) {
        rb_ary_push(out, INT2NUM(gba->video.palette[i]));
    }
    return out;
}

/* --------------------------------------------------------- */
/* Core#scroll(n) — where background n is scrolled to          */
/*                                                            */
/* [across, down], in pixels. These registers are WRITE-ONLY  */
/* on the console, so a game can set them and nothing can read */
/* them back — a test looking at the picture can only guess    */
/* how far a scrolling game has travelled. The emulator kept   */
/* the values it was given.                                    */
/* --------------------------------------------------------- */
static VALUE
mgba_core_scroll(VALUE self, VALUE which)
{
    struct mgba_core *mc = get_mgba_core(self);
    struct GBA *gba;
    int n = NUM2INT(which);
    VALUE out;

    if (mc->core->platform(mc->core) != mPLATFORM_GBA) {
        rb_raise(rb_eRuntimeError, "scroll is GBA-only");
    }
    if (n < 0 || n > 3) {
        rb_raise(rb_eArgError, "there are four backgrounds, 0 to 3 — asked for %d", n);
    }
    gba = (struct GBA *)mc->core->board;

    /* Each background has a pair of registers four bytes apart, starting at BG0's. The
     * io array is indexed in halfwords, hence the shift. */
    out = rb_ary_new_capa(2);
    rb_ary_push(out, INT2NUM(gba->memory.io[(REG_BG0HOFS >> 1) + (n * 2)] & 0x1FF));
    rb_ary_push(out, INT2NUM(gba->memory.io[(REG_BG0VOFS >> 1) + (n * 2)] & 0x1FF));
    return out;
}

/* --------------------------------------------------------- */
/* TAKING THE PICTURE AND THE SOUND APART                     */
/*                                                            */
/* The console composes one picture out of four backgrounds   */
/* and the sprites, and mixes one sound out of six voices.    */
/* Neither the finished picture nor the finished sound can be */
/* asked which of them it came from — so "is the HUD drawing  */
/* at all" and "did that voice sound" have no answer in them. */
/* The emulator can leave one out, and then the question is   */
/* just "what changed".                                       */
/*                                                            */
/* The names come from mGBA rather than from us: it knows     */
/* what it built, and a console it gains a layer on says so   */
/* here without this file being touched.                      */
/* --------------------------------------------------------- */
static VALUE
channel_list(size_t count, const struct mCoreChannelInfo *info)
{
    VALUE out = rb_ary_new_capa((long)count);
    size_t i;

    for (i = 0; i < count; i++) {
        VALUE entry = rb_hash_new();
        rb_hash_aset(entry, ID2SYM(rb_intern("id")), SIZET2NUM(info[i].id));
        rb_hash_aset(entry, ID2SYM(rb_intern("name")), rb_str_new_cstr(info[i].internalName));
        rb_ary_push(out, entry);
    }
    return out;
}

/* Core#video_layers — every layer the console draws with, as {id:, name:}. */
static VALUE
mgba_core_video_layers(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    const struct mCoreChannelInfo *info = NULL;
    size_t count = mc->core->listVideoLayers(mc->core, &info);
    return channel_list(count, info);
}

/* Core#audio_channels — every voice the console mixes, as {id:, name:}. */
static VALUE
mgba_core_audio_channels(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    const struct mCoreChannelInfo *info = NULL;
    size_t count = mc->core->listAudioChannels(mc->core, &info);
    return channel_list(count, info);
}

/* --------------------------------------------------------- */
/* EVERY WRITE THE GAME MAKES TO THE DISPLAY, AND ON WHICH ROW */
/*                                                            */
/* Everything else in this file reads the console once a      */
/* frame, which answers everything while a game sets the      */
/* display up between pictures and then leaves it alone. A    */
/* game that changes the display WHILE the picture is being   */
/* drawn cannot be seen that way at all: a background bent    */
/* row by row writes the same register on all 160 rows, and   */
/* by the time the frame ends only the last of those values   */
/* is still there to read. Every earlier one is gone.         */
/*                                                            */
/* mGBA already taps exactly these writes, for its own        */
/* reasons: its video logger records a frame as a stream of   */
/* packets so another renderer can replay it. Those taps are  */
/* what this wants, so the shim and the taps are mGBA's; the  */
/* stream is decoded back into records here rather than       */
/* written to a file.                                         */
/*                                                            */
/* VRAM WRITES ARE LEFT OUT. What the tap gives for one is an */
/* address with no value — the picture data itself follows as */
/* a 4K block — and a game that draws anything writes         */
/* thousands of them, so keeping them would bury the writes   */
/* somebody asked about. The pictures can be read whole from  */
/* memory afterwards instead.                                 */
/* --------------------------------------------------------- */

enum display_write_kind {
    DISPLAY_WRITE_REGISTER = 0,  /* a display register: where a layer is, how it blends   */
    DISPLAY_WRITE_COLOUR,        /* one of the 512 colours the console draws from         */
    DISPLAY_WRITE_SPRITE         /* one halfword of the table saying where the sprites are */
};

struct display_write {
    uint8_t kind;
    uint16_t row;      /* the row being drawn: 0 to 159 on screen, past that between pictures */
    uint32_t address;
    uint32_t value;
};

struct display_recorder {
    struct GBAVideoProxyRenderer proxy;
    struct mVideoLogger logger;
    struct GBAVideo *video;   /* for the row being drawn when a write lands */
    int count;
    int dropped;
    int skip_next;            /* the next call carries a block of picture data, not a packet */
    struct display_write writes[DISPLAY_WRITES_MAX];
};

/* mGBA hands the stream to this a packet at a time. A packet that carries data after it —
 * a block of picture memory — arrives as a second call, which is skipped rather than read. */
static bool
display_write_data(struct mVideoLogger *logger, const void *data, size_t length)
{
    struct display_recorder *rec = logger->dataContext;
    const struct mVideoLoggerDirtyInfo *packet = data;
    struct display_write *slot;
    uint32_t address;
    uint8_t kind;

    if (rec->skip_next) {
        rec->skip_next = 0;
        return true;
    }
    if (length != sizeof(struct mVideoLoggerDirtyInfo)) {
        return true;
    }

    /* Each tap counts its address its own way — the registers and the colours from the start
     * of their own memory in bytes, the sprite table in halfwords — so each is turned into
     * the address it really landed at. Then every write says where on the console it went,
     * and the same number reads that value back. */
    switch (packet->type) {
    case DIRTY_REGISTER:
        kind = DISPLAY_WRITE_REGISTER;
        address = BASE_IO | packet->address;
        break;
    case DIRTY_PALETTE:
        kind = DISPLAY_WRITE_COLOUR;
        address = BASE_PALETTE_RAM | packet->address;
        break;
    case DIRTY_OAM:
        kind = DISPLAY_WRITE_SPRITE;
        address = BASE_OAM | (packet->address * 2);
        break;
    case DIRTY_VRAM:
    case DIRTY_BUFFER:
        rec->skip_next = 1;
        return true;
    default:
        /* The drawing itself — a scanline done, a frame done — rather than a write. */
        return true;
    }

    if (rec->count >= DISPLAY_WRITES_MAX) {
        rec->dropped++;
        return true;
    }
    slot = &rec->writes[rec->count++];
    slot->kind = kind;
    slot->row = (uint16_t)(rec->video ? rec->video->vcount : 0);
    slot->address = address;
    slot->value = packet->value;
    return true;
}

static void
display_post_event(struct mVideoLogger *logger, enum mVideoLoggerEvent event)
{
    (void)logger;
    (void)event;
}

static void
display_lock_nothing(struct mVideoLogger *logger)
{
    (void)logger;
}

static void
display_wake_nothing(struct mVideoLogger *logger, int y)
{
    (void)logger;
    (void)y;
}

static void
display_recorder_free(struct mgba_core *mc)
{
    struct GBA *gba;

    if (!mc->display) {
        return;
    }
    if (!mc->destroyed && mc->core && mc->core->platform(mc->core) == mPLATFORM_GBA) {
        gba = (struct GBA *)mc->core->board;
        GBAVideoProxyRendererUnshim(&gba->video, &mc->display->proxy);
    }
    free(mc->display);
    mc->display = NULL;
}

/* The renderer that really draws. While the writes are being recorded there is a shim in
 * front of it, and anything reaching past the public renderer — the row cache, the flags
 * saying which layers to leave out — belongs to the one behind. */
static struct GBAVideoRenderer *
drawing_renderer(struct mgba_core *mc)
{
    struct GBA *gba = (struct GBA *)mc->core->board;
    if (mc->display) {
        return mc->display->proxy.backend;
    }
    return gba->video.renderer;
}

/* --------------------------------------------------------- */
/* MAKE THE CONSOLE DRAW THE WHOLE PICTURE AGAIN.             */
/*                                                            */
/* mGBA does not redraw a row of the screen whose registers   */
/* have not moved since the last frame — a large saving on a  */
/* still picture, and the reason switching a layer off can    */
/* look like it did nothing: the rows were never drawn again, */
/* so the layer is still in the picture they kept. A game     */
/* with something moving hides it, which is worse, because    */
/* then it works until the frame nothing happens on.          */
/*                                                            */
/* Every row is marked as needing a redraw, which is what the */
/* renderer's own cache is asked for. It reaches past the     */
/* public renderer to the software one, which is the only one */
/* this binding ever builds.                                  */
/*                                                            */
/* Done before EVERY frame, not only when a layer is hidden:  */
/* the cache also goes wrong on its own. A write to the       */
/* display settings landing part-way through a row can leave  */
/* that row's saved settings looking unchanged, and the row   */
/* is then never drawn again — a cartridge that switched the  */
/* picture off for its first frame kept one white row for the */
/* rest of the run. The console itself draws every row of     */
/* every frame, so this is the emulator doing the same.       */
/* --------------------------------------------------------- */
static void
redraw_everything(struct mgba_core *mc)
{
    struct GBAVideoSoftwareRenderer *renderer;
    size_t i;

    if (mc->core->platform(mc->core) != mPLATFORM_GBA) {
        return;
    }
    renderer = (struct GBAVideoSoftwareRenderer *)drawing_renderer(mc);
    for (i = 0; i < sizeof(renderer->scanlineDirty) / sizeof(renderer->scanlineDirty[0]); i++) {
        renderer->scanlineDirty[i] = 0xFFFFFFFF;
    }
}

/* Which layers to leave out is set on whatever renderer is public, and while the writes are
 * being recorded that is the shim — which draws nothing itself. The renderer behind it is
 * the one that reads these, so they are carried across. */
static void
carry_layer_choices_across(struct mgba_core *mc)
{
    struct GBA *gba;
    struct GBAVideoRenderer *shim, *drawing;
    int i;

    if (!mc->display) {
        return;
    }
    gba = (struct GBA *)mc->core->board;
    shim = gba->video.renderer;
    drawing = drawing_renderer(mc);
    for (i = 0; i < 4; i++) {
        drawing->disableBG[i] = shim->disableBG[i];
    }
    drawing->disableOBJ = shim->disableOBJ;
    drawing->disableWIN[0] = shim->disableWIN[0];
    drawing->disableWIN[1] = shim->disableWIN[1];
    drawing->disableOBJWIN = shim->disableOBJWIN;
}

/* Core#enable_video_layer(id, on) — leave a layer out of the picture, or put it back. */
static VALUE
mgba_core_enable_video_layer(VALUE self, VALUE id, VALUE on)
{
    struct mgba_core *mc = get_mgba_core(self);
    mc->core->enableVideoLayer(mc->core, NUM2SIZET(id), RTEST(on));
    carry_layer_choices_across(mc);
    redraw_everything(mc);
    return on;
}

/* Core#watch_display — start recording what the game writes to the display. */
static VALUE
mgba_core_watch_display(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    struct GBA *gba;
    struct display_recorder *rec;

    if (mc->core->platform(mc->core) != mPLATFORM_GBA) {
        rb_raise(rb_eRuntimeError, "watching the display is GBA-only");
    }
    if (mc->display) {
        return self;
    }
    gba = (struct GBA *)mc->core->board;
    rec = calloc(1, sizeof(struct display_recorder));
    if (!rec) {
        rb_raise(rb_eNoMemError, "there is not enough memory to record the display writes");
    }
    rec->video = &gba->video;

    mVideoLoggerRendererCreate(&rec->logger, false);
    rec->logger.writeData = display_write_data;
    rec->logger.postEvent = display_post_event;
    rec->logger.dataContext = rec;
    rec->logger.block = false;
    rec->logger.waitOnFlush = false;
    rec->logger.lock = display_lock_nothing;
    rec->logger.unlock = display_lock_nothing;
    rec->logger.wait = display_lock_nothing;
    rec->logger.wake = display_wake_nothing;

    rec->proxy.logger = &rec->logger;
    GBAVideoProxyRendererCreate(&rec->proxy, gba->video.renderer);
    GBAVideoProxyRendererShim(&gba->video, &rec->proxy);

    mc->display = rec;
    carry_layer_choices_across(mc);
    return self;
}

/* Core#take_display_writes — hand over what has been recorded and start the record again. */
static VALUE
mgba_core_take_display_writes(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    VALUE out = rb_ary_new();
    int i;

    if (!mc->display) {
        return out;
    }
    for (i = 0; i < mc->display->count; i++) {
        struct display_write *w = &mc->display->writes[i];
        VALUE entry = rb_hash_new();
        rb_hash_aset(entry, ID2SYM(rb_intern("kind")), INT2NUM(w->kind));
        rb_hash_aset(entry, ID2SYM(rb_intern("row")), INT2NUM(w->row));
        rb_hash_aset(entry, ID2SYM(rb_intern("address")), UINT2NUM(w->address));
        rb_hash_aset(entry, ID2SYM(rb_intern("value")), UINT2NUM(w->value));
        rb_ary_push(out, entry);
    }
    mc->display->count = 0;
    return out;
}

/* Core#display_writes_missed — how many went past the record's size. */
static VALUE
mgba_core_display_writes_missed(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    return INT2NUM(mc->display ? mc->display->dropped : 0);
}

/* --------------------------------------------------------- */
/* FINDING WHICH ADDRESS HOLDS A NUMBER                       */
/*                                                            */
/* A cartridge this framework built needs none of this: the   */
/* build knows where every variable went and will say. A      */
/* cartridge it did NOT build has no such record, and then    */
/* the only way to an address is from a number you can see on */
/* screen — look for everywhere holding it, let the game run, */
/* and narrow to the places that moved the way the number     */
/* did. That is how anybody finds a value in a game they did  */
/* not write, and mGBA already does it.                       */
/*                                                            */
/* Writable memory only. A game's state is in the console's   */
/* memory, never in the cartridge, so searching the cartridge */
/* would add megabytes of certainly-wrong answers.            */
/* --------------------------------------------------------- */

/* How many places one look will keep. A first look for a common number — 0, or 1 — matches
 * far more than this, and then the address wanted may not be among the ones kept. Starting
 * from a rarer number is the answer, and the count coming back full is the sign. */
#define SEARCH_KEEP_MAX 10000

static void
search_free(struct mgba_core *mc)
{
    if (!mc->search) {
        return;
    }
    mCoreMemorySearchResultsDeinit(mc->search);
    free(mc->search);
    mc->search = NULL;
}

static void
search_params(struct mCoreMemorySearchParams *params, enum mCoreMemorySearchOp op, int32_t value)
{
    params->memoryFlags = mCORE_MEMORY_RW;
    params->type = mCORE_MEMORY_SEARCH_INT;
    params->op = op;
    params->align = -1;
    params->width = 4;
    params->valueInt = value;
}

static VALUE
search_addresses(struct mgba_core *mc)
{
    VALUE out;
    size_t i, count;

    if (!mc->search) {
        return rb_ary_new();
    }
    count = mCoreMemorySearchResultsSize(mc->search);
    out = rb_ary_new_capa((long)count);
    for (i = 0; i < count; i++) {
        struct mCoreMemorySearchResult *found = mCoreMemorySearchResultsGetPointer(mc->search, i);
        rb_ary_push(out, UINT2NUM(found->address));
    }
    return out;
}

/* Core#addresses_holding(value) — every writable address holding that whole number. */
static VALUE
mgba_core_addresses_holding(VALUE self, VALUE value)
{
    struct mgba_core *mc = get_mgba_core(self);
    struct mCoreMemorySearchParams params;

    search_free(mc);
    mc->search = calloc(1, sizeof(struct mCoreMemorySearchResults));
    if (!mc->search) {
        rb_raise(rb_eNoMemError, "there is not enough memory to search with");
    }
    mCoreMemorySearchResultsInit(mc->search, 0);
    search_params(&params, mCORE_MEMORY_SEARCH_EQUAL, (int32_t)NUM2LONG(value));
    mCoreMemorySearch(mc->core, &params, mc->search, SEARCH_KEEP_MAX);
    return search_addresses(mc);
}

/* Core#narrow_to(op, value) — of those addresses, the ones that still match. */
static VALUE
mgba_core_narrow_to(VALUE self, VALUE op, VALUE value)
{
    struct mgba_core *mc = get_mgba_core(self);
    struct mCoreMemorySearchParams params;

    if (!mc->search) {
        rb_raise(rb_eRuntimeError,
                 "there is nothing to narrow. Look for a value first, then narrow what that found.");
    }
    search_params(&params, (enum mCoreMemorySearchOp)NUM2INT(op), (int32_t)NUM2LONG(value));
    mCoreMemorySearchRepeat(mc->core, &params, mc->search);
    return search_addresses(mc);
}

/* Core#enable_audio_channel(id, on) — leave a voice out of the mix, or put it back. */
static VALUE
mgba_core_enable_audio_channel(VALUE self, VALUE id, VALUE on)
{
    struct mgba_core *mc = get_mgba_core(self);
    mc->core->enableAudioChannel(mc->core, NUM2SIZET(id), RTEST(on));
    return on;
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

/* Core#profile_gb(frames) — A GAME BOY CARTRIDGE'S NEXT +frames+ FRAMES, AN INSTRUCTION AT A TIME,
 * and where the time went: for every instruction that ran, the cycles spent on it.
 *
 * The Game Boy's processor sees one bank of the cartridge at 0x4000 at a time, so an address there
 * means nothing without the bank, and each is counted under both: the key is bank × 0x10000 plus
 * the address. Everything else — bank 0, and code run from memory — is bank 0.
 *
 * Asleep (HALT, waiting for the screen) is counted apart and in cycles, as #profile counts it for
 * the Advance: a sleep is one step however long it lasts, and the address it went to sleep at did
 * not spend that time.
 *
 * Answers { spent: { key => cycles }, halted: cycles, total: cycles }, in the emulator's clock. */
#define GB_PROFILE_BANKS 128
static VALUE
mgba_core_profile_gb(VALUE self, VALUE frames_v)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GB)
        rb_raise(rb_eArgError, "profile_gb plays a Game Boy cartridge, and this is not one");
    struct mCore *core = mc->core;
    struct GB *gb = (struct GB *)core->board;
    long frames = NUM2LONG(frames_v);
    uint32_t *fixed = calloc(0x10000, sizeof(uint32_t));
    uint32_t *banked = calloc((size_t)GB_PROFILE_BANKS * 0x4000, sizeof(uint32_t));
    if (!fixed || !banked) {
        free(fixed);
        free(banked);
        rb_raise(rb_eNoMemError, "no room to count a profile");
    }
    uint64_t halted = 0, total = 0;
    /* Frames are counted as the screen draws them: in double speed the processor's clock runs
     * twice as fast as the frame's, so a frame's worth of cycles is not a frame. */
    uint32_t until = core->frameCounter(core) + (uint32_t)frames;
    long guard = 0;
    long most = (long)core->frameCycles(core) * 8 * (frames + 1);
    {
        while (core->frameCounter(core) != until && ++guard < most) {
            uint64_t before = mTimingGlobalTime(&gb->timing);
            int was_halted = gb->cpu->halted;
            uint16_t pc = gb->cpu->pc;
            int bank = gb->memory.currentBank;
            core->step(core);
            uint64_t took = mTimingGlobalTime(&gb->timing) - before;
            total += took;
            if (was_halted || gb->cpu->halted) /* asleep, or the step that went to sleep and slept */
                halted += took;
            else if (pc >= 0x4000 && pc < 0x8000 && bank < GB_PROFILE_BANKS)
                banked[(size_t)bank * 0x4000 + (pc - 0x4000)] += (uint32_t)took;
            else
                fixed[pc] += (uint32_t)took;
        }
    }
    VALUE spent = rb_hash_new();
    for (long pc = 0; pc < 0x10000; ++pc)
        if (fixed[pc])
            rb_hash_aset(spent, LONG2NUM(pc), ULONG2NUM(fixed[pc]));
    for (long i = 0; i < (long)GB_PROFILE_BANKS * 0x4000; ++i)
        if (banked[i])
            rb_hash_aset(spent, LONG2NUM((i / 0x4000) * 0x10000 + 0x4000 + (i % 0x4000)), ULONG2NUM(banked[i]));
    free(fixed);
    free(banked);
    VALUE out = rb_hash_new();
    rb_hash_aset(out, ID2SYM(rb_intern("spent")), spent);
    rb_hash_aset(out, ID2SYM(rb_intern("halted")), ULL2NUM(halted));
    rb_hash_aset(out, ID2SYM(rb_intern("total")), ULL2NUM(total));
    return out;
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

/* Step through one frame of emulated time and split it into two costs:
 *   busy   — cycles the CPU spent EXECUTING instructions (not halted).
 *   active — the frame's wall-clock work: everything that is not the
 *            end-of-frame halt (executing PLUS the DMA-stall).
 *
 * Why two numbers. A GBA frame is exactly frameCycles of global time. In that
 * frame the CPU is either halted (asleep in the vblank wait) or not halted
 * (doing something). "Not halted" covers real instruction work AND the stall
 * while a DMA engine copies — during an immediate DMA the CPU is frozen but it
 * is NOT the halt sleep, so those cycles never land in cpu->cycles and the busy
 * count cannot see them. So we measure the halt directly and take the rest:
 *   active = frameCycles - (global time spent halted).
 * That captures the DMA-stall the busy count misses, without depending on how
 * mGBA books DMA cycles internally.
 *
 * Global time (timing.globalCycles) only jumps forward on the halted
 * "fast-forward to the next event" step and at event boundaries; while the CPU
 * executes, its cycles accumulate in cpu->cycles and global time stays frozen.
 * So busy is the sum of cpu->cycles gained on non-halted steps, and the halted
 * time is the sum of global jumps taken while the CPU is asleep.
 *
 * Both numbers are meaningful only for a per-frame workload that FITS in a
 * frame. A ROM that cannot finish its work in one frame has no single per-frame
 * cost — the numbers cap out near a full frame and wobble as work bleeds across
 * frames. That is the honest answer for an over-budget game.
 *
 * TWO KNOWN LIMITS ON `busy`, measured rather than reasoned about, because both
 * are easy to rediscover and neither is worth a heuristic to paper over.
 *
 * IT UNDERCOUNTS BY A LITTLE. mGBA drains due events before an instruction and
 * ZEROES cpu->cycles when it does, so on such a step the delta below is negative
 * and the guard throws that one instruction's cycles away. What went before it
 * was already counted and the next step starts from zero again, so the loss is
 * one instruction per drained step and no more. Measured over a frame: 14
 * dropped steps of 3713 on a loop of arithmetic (0.4 per cent), 276 of 26601 on
 * a screenful of small fills (1.0 per cent), 171 of 2691 on a full-screen DMA
 * fill (6.4 per cent of a busy figure that is tiny to begin with). So the loss
 * is largest where the CPU is doing LEAST — a frame of events and few
 * instructions — which is the opposite of the shape to worry about. Recovering
 * it exactly is not possible from outside: the drained total is folded into
 * global time along with whatever the events themselves did, and on a DMA step
 * that is the transfer, so adding it back would fold the stall into `busy` and
 * destroy the very split these two numbers are for.
 *
 * AND IT CAN EXCEED `active`, which cannot be true of the real machine: 5899
 * against 5142 on that same loop of arithmetic. The two are counted off
 * different clocks — `busy` off the CPU's own accumulator, `active` off global
 * time with the last halt clamped to the frame edge — so they disagree at the
 * edges. Callers that need one number take the larger of the two rather than
 * trusting either alone, and dma_cycles clamps the difference at zero.
 *
 * WHAT NONE OF THIS AFFECTS: RubyGBA's profiler, which counts instructions by
 * sampling the program counter and reads its sleep off global time. Nothing
 * that decides anything goes through here. */
static inline uint32_t
executing_pc(struct ARMCore *cpu);

static void
measure_frame_split(struct mgba_core *mc, int64_t *out_busy, int64_t *out_active)
{
    struct mCore *core = mc->core;
    struct GBA *gba = (struct GBA *)core->board;

    int32_t frame_c = core->frameCycles(core);
    uint64_t start_gc = gba->timing.globalCycles;
    int64_t busy = 0;
    uint64_t halted = 0;

    /* Safety cap: at worst one single-cycle step per cycle, so a frame can't
     * take more than frameCycles iterations. A generous multiple guards against
     * a step that fails to advance time (which would otherwise spin forever). */
    long guard = 0;
    long max_iters = (long)frame_c * 4;

    while ((gba->timing.globalCycles - start_gc) < (uint64_t)frame_c
           && ++guard < max_iters) {
        int was_halted = gba->cpu->halted;
        int32_t before = gba->cpu->cycles;
        uint64_t g_before = gba->timing.globalCycles;
        core->step(core);
        /* This route never asks the debugger anything, so an arrival being counted has to be
         * spotted here — the same comparison the debugger makes, in the same place, right
         * after a step. Without it a caller measuring a window's cost would see its pass
         * count stand still for the whole window. */
        if (mc->counting_arrivals && executing_pc(gba->cpu) == mc->arrival_address)
            mc->arrivals++;
        int32_t delta = gba->cpu->cycles - before;
        if (!was_halted && delta > 0)
            busy += delta;
        if (was_halted) {
            /* Global jump this step, clamped to the frame boundary so the final
             * halt step's fast-forward past the frame end isn't counted. */
            uint64_t g_delta = gba->timing.globalCycles - g_before;
            uint64_t elapsed = gba->timing.globalCycles - start_gc;
            if (elapsed > (uint64_t)frame_c) {
                uint64_t over = elapsed - (uint64_t)frame_c;
                g_delta = over < g_delta ? g_delta - over : 0;
            }
            halted += g_delta;
        }
    }
    *out_busy = busy;
    *out_active = (int64_t)frame_c - (int64_t)halted;
}

/* Core#measure_frame_busy_cycles — one frame's CPU-executing cycles (not
 * halted, and not counting DMA-stall). Call it on a ROM already at steady state
 * (run a few frames first) to read the per-frame CPU cost of its game loop.
 * GBA-only. */
static VALUE
mgba_core_measure_frame_busy_cycles(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA)
        rb_raise(rb_eRuntimeError, "measure_frame_busy_cycles is GBA-only");

    int64_t busy, active;
    measure_frame_split(mc, &busy, &active);
    return LL2NUM(busy);
}

/* Core#measure_frame_work — one frame's cost as [busy, active]: the
 * CPU-executing cycles and the wall-clock work (executing plus DMA-stall).
 * Their difference is the DMA-stall time the busy count alone misses. One pass,
 * so both numbers describe the same measured frame. GBA-only. */
static VALUE
mgba_core_measure_frame_work(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA)
        rb_raise(rb_eRuntimeError, "measure_frame_work is GBA-only");

    int64_t busy, active;
    measure_frame_split(mc, &busy, &active);
    VALUE out = rb_ary_new_capa(2);
    rb_ary_push(out, LL2NUM(busy));
    rb_ary_push(out, LL2NUM(active));
    return out;
}

/* --------------------------------------------------------- */
/* Profiling — where the CPU actually spent its frames        */
/*                                                            */
/* The cycle measurements above say how much a frame costs.   */
/* They cannot say WHICH code it was spent in, and that is    */
/* the question somebody with a slow game actually has.       */
/*                                                            */
/* So: step the emulation one instruction at a time and, at   */
/* each step, write down the address about to run. Tally      */
/* those and the shape of the frame falls out — the addresses */
/* that come up most are where the time went. That is what    */
/* every profiler does; the only thing particular to an       */
/* emulator is that the sampling is exact rather than         */
/* statistical, because we can look at every instruction      */
/* instead of interrupting a real CPU periodically.           */
/*                                                            */
/* This stays a probe: it hands back raw counts against raw   */
/* addresses. Turning an address into the name of a routine   */
/* needs the build that made the ROM, which is not here.      */
/* --------------------------------------------------------- */

/* Where executable code can live. Registers, video memory and the like are
 * left out: nothing runs from them, and a sample landing outside these is
 * counted as elsewhere rather than silently dropped. */
enum {
    PROF_BIOS = 0,
    PROF_EWRAM,
    PROF_IWRAM,
    PROF_ROM,
    PROF_REGIONS
};

/* Counts per halfword, not per word, so Thumb code lands on its own
 * instructions rather than two of them sharing a slot. ARM code simply leaves
 * every odd slot empty. */
#define PROF_GRAIN 2

/* The most passes one profile keeps: one a frame for longer than anybody profiles. */
#define PROF_PASSES_MAX 4096

struct pc_tally {
    uint32_t *count[PROF_REGIONS];
    /* CYCLES each address took, beside how many times it ran. Not the same thing: a store that
     * starts the console's copy engine is one instruction, and the processor then stands still
     * until the copy is done, so that one instruction can take most of a frame. Counting it once
     * is how a whole-screen copy went unseen. Each step's cycles are charged to the instruction
     * it ran, which is the instruction that started the copy. */
    uint64_t *cycles[PROF_REGIONS];
    uint64_t *copier;    /* where the copy now under way was started, or NULL */
    size_t    slots[PROF_REGIONS];
    /* EACH PASS OF THE GAME, and how close it came. The wait at the end of a game's pass waits
     * for the NEXT break between pictures, so a pass that goes to sleep a line after a break began
     * sleeps a whole picture. +breaks_began+ counts the breaks that began while the game was
     * awake; +last_line+ is the line the screen was on at the step before; +games_code_ran+ says
     * the game's own code ran since it last woke, outside any interrupt's handler.
     *
     * Every pass is kept in the order they ended: +missed+ is how many breaks began while it ran,
     * each a picture it was not ready for, and +ended_before+ how many lines before the next break
     * it went to sleep, below nothing for one asleep inside a break it missed (see
     * lines_before_break). That last is a pass a few lines late, and the Ruby side reads the late
     * passes out of these. */
    int       breaks_began;
    int       last_line;
    int       games_code_ran;
    int      *missed;
    int      *ended_before;
    size_t    pass_count;
    uint64_t  samples;   /* instructions seen */
    uint64_t  halted;    /* CYCLES slept, not steps — see profile_one_frame */
    uint64_t  elsewhere; /* executing somewhere we have no room to count */
    uint64_t  finished;  /* frames the game got its work done in — see below */
    int       awake;     /* was it running when last looked at? carried across frames */
};

/* Which region an address belongs to, and how far into it. Returns -1 for an
 * address nothing executes from.
 *
 * The cartridge appears THREE TIMES over — at 0x08000000, 0x0A000000 and
 * 0x0C000000 — which are the same bytes offered at three different memory
 * speeds. They fold together here, or one routine would be counted as three
 * depending on which mirror the build happened to reach it through. */
static int
pc_region(uint32_t addr, uint32_t *offset)
{
    switch (addr >> BASE_OFFSET) {
    case 0x0: *offset = addr & (SIZE_BIOS - 1);         return PROF_BIOS;
    case 0x2: *offset = addr & (SIZE_WORKING_RAM - 1);  return PROF_EWRAM;
    case 0x3: *offset = addr & (SIZE_WORKING_IRAM - 1); return PROF_IWRAM;
    case 0x8: case 0x9:
    case 0xA: case 0xB:
    case 0xC: case 0xD: *offset = addr & 0x01FFFFFF;    return PROF_ROM;
    default: return -1;
    }
}

/* The base address each region's counts are reported against, so a caller can
 * turn a slot back into the address it stands for. */
static const uint32_t PROF_BASE[PROF_REGIONS] = {
    BASE_BIOS, BASE_WORKING_RAM, BASE_WORKING_IRAM, BASE_CART0
};

static void
pc_tally_free(struct pc_tally *t)
{
    for (int r = 0; r < PROF_REGIONS; ++r) {
        free(t->count[r]);
        free(t->cycles[r]);
        t->count[r] = NULL;
        t->cycles[r] = NULL;
        t->slots[r] = 0;
    }
    free(t->missed);
    t->missed = NULL;
    free(t->ended_before);
    t->ended_before = NULL;
}

/* Flat arrays rather than a hash: an address maps straight to a slot, so the
 * tally costs one add per instruction and cannot degrade. The cartridge array
 * is sized to the ROM actually loaded — a cartridge region is 32MB of address
 * space and almost none of it is real. */
static int
pc_tally_init(struct pc_tally *t, size_t rom_bytes)
{
    memset(t, 0, sizeof(*t));
    size_t bytes[PROF_REGIONS] = {
        SIZE_BIOS, SIZE_WORKING_RAM, SIZE_WORKING_IRAM, rom_bytes
    };
    for (int r = 0; r < PROF_REGIONS; ++r) {
        t->slots[r] = bytes[r] / PROF_GRAIN;
        if (t->slots[r] == 0)
            continue;
        t->count[r] = calloc(t->slots[r], sizeof(uint32_t));
        t->cycles[r] = calloc(t->slots[r], sizeof(uint64_t));
        if (!t->count[r] || !t->cycles[r]) {
            pc_tally_free(t);
            return 0;
        }
    }
    t->missed = calloc(PROF_PASSES_MAX, sizeof(int));
    t->ended_before = calloc(PROF_PASSES_MAX, sizeof(int));
    if (!t->missed || !t->ended_before) {
        pc_tally_free(t);
        return 0;
    }
    return 1;
}

/* Count one instruction at +addr+, and hand back where its cycles go once it has run — NULL for
 * an address with no room to count it. */
static inline uint64_t *
pc_tally_hit(struct pc_tally *t, uint32_t addr)
{
    uint32_t offset;
    int region = pc_region(addr, &offset);
    size_t slot = offset / PROF_GRAIN;
    if (region < 0 || slot >= t->slots[region]) {
        t->elsewhere++;
        return NULL;
    }
    t->count[region][slot]++;
    return &t->cycles[region][slot];
}

/* THE ADDRESS OF THE INSTRUCTION ABOUT TO RUN, which is not what r15 holds.
 *
 * This chip reads ahead while it works, so r15 is never the address that is
 * running. How far ahead depends on WHERE YOU ASK, and the difference is the
 * one thing about this that is easy to get wrong: mid-instruction r15 is two
 * instructions past, which is the figure the ARM manuals quote — but BETWEEN
 * two steps, which is where this asks, it is exactly ONE instruction past.
 * So one instruction's width comes off: four bytes of ARM code, or two of
 * Thumb, a Thumb instruction being half the size.
 *
 * mGBA's own debugger does the same subtraction in the same place — see
 * _readPC in its gdb stub, and ARMDebuggerCheckBreakpoints, which is called
 * immediately after a step exactly as this is.
 *
 * Getting this wrong is quiet, which is why it is spelled out. Every address
 * would move by the same four bytes, so every count stays where it was and
 * every test of the SHAPE of a profile still passes — a loop's body is still
 * counted once a pass. The report simply blames the instruction before the one
 * doing the work. Nothing but a reading of the emulator's own source says so.
 *
 * The mode is read from cpsr rather than executionMode because that is the one
 * the processor itself switches, and it is read here, beside the register, so a
 * branch that changes mode cannot be answered with the mode from before it. */
static inline uint32_t
executing_pc(struct ARMCore *cpu)
{
    uint32_t width = cpu->cpsr.t ? WORD_SIZE_THUMB : WORD_SIZE_ARM;
    return (uint32_t)cpu->gprs[ARM_PC] - width;
}

/* Which of the four copy engines have a copy under way that runs the moment it is started, as a
 * mask. Those are the copies that stop the processor at a time the program chose. One that waits
 * for the screen or the sound to ask for it stays switched on between runs, and is left out: its
 * stalls still land on whatever instruction is running when it takes over. */
static unsigned
copies_under_way(struct GBA *gba)
{
    unsigned mask = 0;
    for (int i = 0; i < 4; ++i) {
        GBADMARegister reg = gba->memory.dma[i].reg;
        if (GBADMARegisterIsEnable(reg) && GBADMARegisterGetTiming(reg) == 0)
            mask |= 1u << i;
    }
    return mask;
}

/* HOW MANY LINES BEFORE THE NEXT BREAK A PASS WENT TO SLEEP, given the line it slept on and
 * how many breaks began while it ran. The screen draws 160 lines of picture and then 68 of break,
 * 228 in all.
 *
 * Counted from the line before the break: asleep on that line is nought to spare, and asleep on
 * the break's first line is one late (one line sooner would have made it), so -1. A pass asleep in a
 * break that began before it did (one woken by that break) is due by the break after, so it had
 * the rest of this break and the whole next picture. Breaks the pass ran through before the one it
 * slept near are not in this number: they are counted beside it. */
static int
lines_before_break(int breaks_began, int line)
{
    int before = GBA_VIDEO_VERTICAL_PIXELS - 1 - line;
    if (line >= GBA_VIDEO_VERTICAL_PIXELS && breaks_began == 0)
        before += VIDEO_VERTICAL_TOTAL_PIXELS;
    return before;
}

/* Step one frame, writing down where the CPU was at each step.
 *
 * The frame is walked the same way measure_frame_split walks it — by global
 * time, since that is what advances by exactly a frame — so the two agree
 * about where a frame ends.
 *
 * A SLEEP IS COUNTED APART, AND IN CYCLES RATHER THAN STEPS. When a game has
 * finished its work it sleeps until the screen comes round, and the emulator
 * answers that by jumping straight to whatever is due next. So the sleep is ONE
 * step however long it lasts, and counting steps would say a game that slept
 * nine tenths of its frame slept twice. What the sleep is worth is the time it
 * covered, so the clock is read either side of it.
 *
 * It gets no address at all, which is the point of separating it. The address
 * sitting in r15 while a game sleeps is wherever it happened to go to sleep,
 * and blaming that line for the wait would be the most misleading thing this
 * could report. */
static void
profile_one_frame(struct mgba_core *mc, struct pc_tally *t)
{
    struct mCore *core = mc->core;
    struct GBA *gba = (struct GBA *)core->board;

    int32_t frame_c = core->frameCycles(core);
    uint64_t start_gc = gba->timing.globalCycles;
    int slept_this_frame = 0;

    long guard = 0;
    long max_iters = (long)frame_c * 4;

    while ((gba->timing.globalCycles - start_gc) < (uint64_t)frame_c
           && ++guard < max_iters) {
        uint64_t before = gba->timing.globalCycles;

        if (!gba->cpu->halted) {
            uint32_t pc = executing_pc(gba->cpu);
            uint64_t *spent = pc_tally_hit(t, pc);
            unsigned copying = copies_under_way(gba);
            /* Read before the step: a long step (a slow load, a copy) can be followed straight
             * away by an interrupt's handler, and after it the game's code would not look like
             * the game's. */
            int games_code = gba->cpu->cpsr.priv != MODE_IRQ && pc >= SIZE_BIOS;
            /* mTimingGlobalTime, not globalCycles: the emulator brings globalCycles up to date
             * only when it next has something scheduled to do, so between two of those every
             * step reads as nothing and the step that catches up reads as all of it. */
            uint64_t started = mTimingGlobalTime(&gba->timing);
            t->samples++;
            t->awake = 1;
            core->step(core);
            uint64_t took = mTimingGlobalTime(&gba->timing) - started;
            unsigned now = copies_under_way(gba);

            /* A COPY TAKES OVER A FEW CYCLES AFTER THE STORE THAT STARTS IT, so the stall lands on
             * whichever instruction runs then — often the return from the routine that started
             * it, and so the next routine's. While a copy is under way, each step's cycles go to
             * the instruction that started it. */
            uint64_t *charged = (copying && t->copier) ? t->copier : spent;
            if (charged)
                *charged += took;
            if (now & ~copying)
                t->copier = spent;
            else if (!now)
                t->copier = NULL;

            /* The break between pictures begins as the screen reaches its first line below the
             * picture, and it counts against the pass whatever is running as it does: a timer's
             * handler or the console's own divide, taken in the middle of a pass, is still that
             * pass's time. The break that WAKES a sleeping game is not counted, because the line
             * is brought up to date across the sleep below. */
            int line = gba->video.vcount;
            if (t->last_line < GBA_VIDEO_VERTICAL_PIXELS && line >= GBA_VIDEO_VERTICAL_PIXELS)
                t->breaks_began++;
            t->last_line = line;
            if (games_code)
                t->games_code_ran = 1;
            continue;
        }

        /* GOING to sleep, rather than being found already asleep. A run that
         * starts partway through a wait would otherwise count that leftover as
         * this frame's finish, and one frame in a whole run is enough to read
         * 30.3 where the game is doing a clean 30. */
        if (t->awake) {
            slept_this_frame = 1;
            int line = gba->video.vcount;
            /* A wake that ran only an interrupt's handler and went back to sleep — a timer going
             * off while the game waits for the screen — is not a pass of the game. */
            if (t->games_code_ran && t->pass_count < PROF_PASSES_MAX) {
                t->missed[t->pass_count] = t->breaks_began;
                t->ended_before[t->pass_count++] = lines_before_break(t->breaks_began, line);
            }
            t->breaks_began = 0;
            t->games_code_ran = 0;
        }
        t->awake = 0;

        core->step(core);
        t->last_line = gba->video.vcount;

        /* Clamped to the frame's end, so the step that sleeps past the boundary
         * does not charge this frame for the next one's wait. */
        uint64_t slept = gba->timing.globalCycles - before;
        uint64_t elapsed = gba->timing.globalCycles - start_gc;
        if (elapsed > (uint64_t)frame_c) {
            uint64_t over = elapsed - (uint64_t)frame_c;
            slept = over < slept ? slept - over : 0;
        }
        t->halted += slept;
    }

    /* DID THE GAME FINISH ITS WORK IN THIS FRAME? That is what it sleeping says.
     *
     * A game loop ends by waiting for the screen, so a game that made its
     * deadline is asleep by the end of the frame and one that did not is still
     * working when the frame runs out. Count the frames it finished in and the
     * console's real rate falls out: finish every frame and that is sixty a
     * second, finish one in three and it is twenty.
     *
     * This asks the CONSOLE rather than the game. Nothing is added to the
     * cartridge and nothing is rebuilt, so it can be asked of a ROM that is
     * already built, which is the difference from counting passes with a
     * counter put into the program. */
    if (slept_this_frame)
        t->finished++;
}

/* Add one region's counts to +out+ as address => times seen. Only addresses
 * that came up at all are included, so a game that touches a corner of a large
 * cartridge hands back a small hash. Regions cannot collide — each reports
 * against its own base — so they all go in the one hash. */
static void
pc_region_into(VALUE out, VALUE cycles_out, const struct pc_tally *t, int region)
{
    const uint32_t *count = t->count[region];
    if (!count)
        return;

    for (size_t slot = 0; slot < t->slots[region]; ++slot) {
        if (count[slot] == 0)
            continue;
        uint32_t addr = PROF_BASE[region] + (uint32_t)(slot * PROF_GRAIN);
        rb_hash_aset(out, UINT2NUM(addr), UINT2NUM(count[slot]));
        rb_hash_aset(cycles_out, UINT2NUM(addr), ULL2NUM(t->cycles[region][slot]));
    }
}

/* WHAT THE PROGRAM READ AND WROTE, word by word, in the console's two working memories.
 *
 * The counts of where the processor RAN say what keeping a routine in the quick memory is worth.
 * They cannot say what keeping a list there is worth: a list is not run, it is read, and every read
 * of the roomy memory waits several cycles a read of the quick memory does not. So while a profile
 * runs, the processor's own way of reading and writing memory is wrapped. Each read or write is
 * counted against the word it lands in, and the emulator's own function then does the work. Nothing
 * is added to the cartridge and no access takes a cycle longer.
 *
 * Fetching an instruction does not come through here: the processor reads its code another way,
 * and that is what +pc+ counts. A copy the console's copy engine makes does, since it moves words
 * through the same functions. A load or store of several registers at once is counted a word each.
 *
 * The wrapped functions are told only the processor, so the tally they add to is kept per thread,
 * the same way a watched core is (see GEMBA_PER_THREAD). */
enum { TOUCH_EWRAM = 0, TOUCH_IWRAM, TOUCH_REGIONS };

/* One count a word: a byte or half read counts against the word it is part of. */
#define TOUCH_GRAIN 4

struct touch_tally {
    uint32_t *count[TOUCH_REGIONS];
    size_t    slots[TOUCH_REGIONS];
    struct ARMMemory wrapped; /* the functions the wrappers hand on to */
};

static GEMBA_PER_THREAD struct touch_tally *s_touching = NULL;

static const uint32_t TOUCH_BASE[TOUCH_REGIONS] = { BASE_WORKING_RAM, BASE_WORKING_IRAM };

static inline void
touch_word(uint32_t address)
{
    struct touch_tally *t = s_touching;
    int region;
    uint32_t offset;
    switch (address >> BASE_OFFSET) {
    case 0x2: region = TOUCH_EWRAM; offset = address & (SIZE_WORKING_RAM - 1);  break;
    case 0x3: region = TOUCH_IWRAM; offset = address & (SIZE_WORKING_IRAM - 1); break;
    default: return;
    }
    t->count[region][offset / TOUCH_GRAIN]++;
}

/* Each register a load or store of several moves is a word of its own, one after another up from
 * the lowest. Where that lowest word is depends on which way the instruction walks from its base,
 * and whether it steps before or after each word. */
static void
touch_words(uint32_t base, int mask, enum LSMDirection direction)
{
    int words = __builtin_popcount((unsigned)mask & 0xFFFF);
    uint32_t span = (uint32_t)(words * 4);
    uint32_t lowest;
    switch (direction) {
    case LSM_IA: lowest = base;            break;
    case LSM_IB: lowest = base + 4;        break;
    case LSM_DA: lowest = base - span + 4; break;
    default:     lowest = base - span;     break; /* LSM_DB */
    }
    for (int i = 0; i < words; ++i)
        touch_word(lowest + (uint32_t)(i * 4));
}

static uint32_t
touch_load32(struct ARMCore *cpu, uint32_t address, int *cycles)
{
    touch_word(address);
    return s_touching->wrapped.load32(cpu, address, cycles);
}

static uint32_t
touch_load16(struct ARMCore *cpu, uint32_t address, int *cycles)
{
    touch_word(address);
    return s_touching->wrapped.load16(cpu, address, cycles);
}

static uint32_t
touch_load8(struct ARMCore *cpu, uint32_t address, int *cycles)
{
    touch_word(address);
    return s_touching->wrapped.load8(cpu, address, cycles);
}

static void
touch_store32(struct ARMCore *cpu, uint32_t address, int32_t value, int *cycles)
{
    touch_word(address);
    s_touching->wrapped.store32(cpu, address, value, cycles);
}

static void
touch_store16(struct ARMCore *cpu, uint32_t address, int16_t value, int *cycles)
{
    touch_word(address);
    s_touching->wrapped.store16(cpu, address, value, cycles);
}

static void
touch_store8(struct ARMCore *cpu, uint32_t address, int8_t value, int *cycles)
{
    touch_word(address);
    s_touching->wrapped.store8(cpu, address, value, cycles);
}

static uint32_t
touch_load_multiple(struct ARMCore *cpu, uint32_t base, int mask, enum LSMDirection direction, int *cycles)
{
    touch_words(base, mask, direction);
    return s_touching->wrapped.loadMultiple(cpu, base, mask, direction, cycles);
}

static uint32_t
touch_store_multiple(struct ARMCore *cpu, uint32_t base, int mask, enum LSMDirection direction, int *cycles)
{
    touch_words(base, mask, direction);
    return s_touching->wrapped.storeMultiple(cpu, base, mask, direction, cycles);
}

static void
touch_tally_free(struct touch_tally *t)
{
    for (int r = 0; r < TOUCH_REGIONS; ++r) {
        free(t->count[r]);
        t->count[r] = NULL;
    }
}

static int
touch_tally_init(struct touch_tally *t)
{
    memset(t, 0, sizeof(*t));
    size_t bytes[TOUCH_REGIONS] = { SIZE_WORKING_RAM, SIZE_WORKING_IRAM };
    for (int r = 0; r < TOUCH_REGIONS; ++r) {
        t->slots[r] = bytes[r] / TOUCH_GRAIN;
        t->count[r] = calloc(t->slots[r], sizeof(uint32_t));
        if (!t->count[r]) {
            touch_tally_free(t);
            return 0;
        }
    }
    return 1;
}

/* Put the wrappers in front of the processor's own functions, and take them away again. */
static void
touch_wrap(struct touch_tally *t, struct ARMCore *cpu)
{
    t->wrapped = cpu->memory;
    cpu->memory.load32 = touch_load32;
    cpu->memory.load16 = touch_load16;
    cpu->memory.load8 = touch_load8;
    cpu->memory.store32 = touch_store32;
    cpu->memory.store16 = touch_store16;
    cpu->memory.store8 = touch_store8;
    cpu->memory.loadMultiple = touch_load_multiple;
    cpu->memory.storeMultiple = touch_store_multiple;
    s_touching = t;
}

static void
touch_unwrap(struct touch_tally *t, struct ARMCore *cpu)
{
    cpu->memory.load32 = t->wrapped.load32;
    cpu->memory.load16 = t->wrapped.load16;
    cpu->memory.load8 = t->wrapped.load8;
    cpu->memory.store32 = t->wrapped.store32;
    cpu->memory.store16 = t->wrapped.store16;
    cpu->memory.store8 = t->wrapped.store8;
    cpu->memory.loadMultiple = t->wrapped.loadMultiple;
    cpu->memory.storeMultiple = t->wrapped.storeMultiple;
    s_touching = NULL;
}

/* The words touched at all, as address => times. */
static VALUE
touch_tally_hash(const struct touch_tally *t)
{
    VALUE out = rb_hash_new();
    for (int r = 0; r < TOUCH_REGIONS; ++r) {
        for (size_t slot = 0; slot < t->slots[r]; ++slot) {
            if (t->count[r][slot] == 0)
                continue;
            rb_hash_aset(out, UINT2NUM(TOUCH_BASE[r] + (uint32_t)(slot * TOUCH_GRAIN)), UINT2NUM(t->count[r][slot]));
        }
    }
    return out;
}

/* Core#profile(frames, keys) — run that many frames and report where the CPU
 * was. Returns a Hash:
 *
 *   :samples   how many instructions were seen
 *   :halted    CYCLES spent asleep waiting for the screen — time, not code
 *   :elsewhere instructions executing somewhere with no room to count them
 *   :frames    frames actually run
 *   :finished  of those, how many the game got its work done in
 *   :pc        { address => times seen }
 *   :cycles    { address => cycles it took }, a copy it started included
 *   :passes    for every pass, [breaks that began while it ran, lines before the next
 *              break it went to sleep] — below nothing asleep inside a break it missed
 *   :touches   { word address => reads and writes } in the two working memories
 *
 * The caller decides what has settled and what to hold: run it after stepping
 * past the boot frames, with whatever keys the measured behaviour needs.
 * GBA-only. */
static VALUE
mgba_core_profile(VALUE self, VALUE rb_frames, VALUE rb_keys)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA)
        rb_raise(rb_eRuntimeError, "profile is GBA-only");

    long frames = NUM2LONG(rb_frames);
    if (frames <= 0)
        rb_raise(rb_eArgError, "frames must be positive, got %ld", frames);

    struct mCore *core = mc->core;
    struct ARMCore *cpu = ((struct GBA *)core->board)->cpu;
    struct pc_tally tally;
    struct touch_tally touched;
    if (!pc_tally_init(&tally, core->romSize(core)))
        rb_raise(rb_eNoMemError, "could not allocate the profile tally");
    if (!touch_tally_init(&touched)) {
        pc_tally_free(&tally);
        rb_raise(rb_eNoMemError, "could not allocate the profile tally");
    }

    if (!NIL_P(rb_keys))
        core->setKeys(core, (uint32_t)NUM2UINT(rb_keys));

    /* From the line the screen is on now, so a profile that starts inside a break does not
     * read the break as having begun under the game's first step. */
    tally.last_line = ((struct GBA *)core->board)->video.vcount;

    touch_wrap(&touched, cpu);
    for (long f = 0; f < frames; ++f)
        profile_one_frame(mc, &tally);
    touch_unwrap(&touched, cpu);

    VALUE out = rb_hash_new();
    rb_hash_aset(out, ID2SYM(rb_intern("frames")),    LONG2NUM(frames));
    rb_hash_aset(out, ID2SYM(rb_intern("samples")),   ULL2NUM(tally.samples));
    rb_hash_aset(out, ID2SYM(rb_intern("halted")),    ULL2NUM(tally.halted));
    rb_hash_aset(out, ID2SYM(rb_intern("elsewhere")), ULL2NUM(tally.elsewhere));
    rb_hash_aset(out, ID2SYM(rb_intern("finished")),  ULL2NUM(tally.finished));

    VALUE pc = rb_hash_new();
    VALUE cycles = rb_hash_new();
    for (int r = 0; r < PROF_REGIONS; ++r)
        pc_region_into(pc, cycles, &tally, r);
    rb_hash_aset(out, ID2SYM(rb_intern("pc")), pc);
    rb_hash_aset(out, ID2SYM(rb_intern("cycles")), cycles);

    VALUE passes = rb_ary_new_capa((long)tally.pass_count);
    for (size_t i = 0; i < tally.pass_count; ++i)
        rb_ary_push(passes, rb_ary_new_from_args(2, INT2NUM(tally.missed[i]), INT2NUM(tally.ended_before[i])));
    rb_hash_aset(out, ID2SYM(rb_intern("passes")), passes);
    rb_hash_aset(out, ID2SYM(rb_intern("touches")), touch_tally_hash(&touched));

    pc_tally_free(&tally);
    touch_tally_free(&touched);
    return out;
}

/* WHAT RECORDED-SOUND CHANNEL A WAS FED AND PLAYED, worked out from the emulator's own state.
 *
 * The channel has a queue of eight words. Each time its timer runs out it plays one sample, the
 * low byte of the word it is on, and moves to the next byte; after four it takes the next word
 * off the queue. Whenever three words or fewer are left it asks its copy engine for four more,
 * which reads them from wherever the engine's read address has got to. Nothing about any of that
 * is in memory a program can read: the mixer's buffers and the speaker are either side of it.
 *
 * So the two things that move the queue are watched as they happen: the timer running out, which
 * plays a sample, and the copy engine moving a word, which puts one in. Each is an event the
 * emulator keeps a function for, and while a feed is recorded that function is wrapped: the
 * queue's places are read, the emulator's own function runs, and they are read again. A word
 * that went in came from the four bytes before where the engine's read address has got to; a word
 * taken off is the one in the slot the queue read from. Which byte of it is played is read off the
 * emulator each time rather than counted here, so nothing here can drift from it. Nothing is added
 * to the cartridge and nothing it does takes a cycle longer, so a fault that hangs on timing is
 * still there to be seen.
 *
 * These run with Ruby's lock released, part-way through a frame, so what they see goes into a
 * plain list of the core's own, and Ruby reads it once the frames are done. Only frames run by
 * Core#run_frame are seen, since that is what says which core a thread is running.
 *
 * A word the program writes into the queue itself, not through the copy engine, is not seen
 * arriving at all, so its slot keeps the word and address that were there before and its samples
 * are put down to those; the framework never does that. A timer running out with the queue empty
 * plays silence, which comes from nowhere and is noted as such, since a queue running dry is
 * exactly the kind of fault this is for. */

/* What a noted event was. */
enum feed_event_kind { FEED_PLAYED, FEED_FETCHED, FEED_SILENCE };

/* Note one thing the feed saw. A list that cannot grow says so rather than stopping the frame. */
static void
feed_log_event(struct mgba_core *mc, int kind, uint32_t from, uint32_t value, uint32_t late)
{
    struct feed_log *log = &mc->feed_log;
    if (log->count == log->room) {
        size_t room = log->room ? log->room * 2 : 4096;
        struct feed_event *grown = realloc(log->events, room * sizeof *grown);
        if (!grown) {
            log->cut_short = 1;
            return;
        }
        log->events = grown;
        log->room = room;
    }
    struct GBA *gba = (struct GBA *)mc->core->board;
    struct feed_event *e = &log->events[log->count++];
    e->at = mTimingGlobalTime(&gba->timing);
    e->line = gba->video.vcount;
    e->kind = kind;
    e->from = from;
    e->value = value;
    e->late = late;
}

/* What the queue holds when nothing has been seen of how it got there: its words, from address 0,
 * which is what a sample of one of them says it came from. */
static void
feed_seed_queue_mirror(struct mgba_core *mc, struct GBAAudioFIFO *fifo)
{
    struct feed_queue_mirror *q = &mc->feed_queue;
    for (int slot = 0; slot < GBA_AUDIO_FIFO_SIZE; ++slot) {
        q->from[slot] = 0;
        q->word[slot] = fifo->fifo[slot];
    }
    /* The word being played has been shifted down by the bytes already played, so it is put back
     * where they were — and a word with none left to play has nothing to put back. */
    int played = 4 - fifo->internalRemaining;
    q->playing_from = 0;
    q->playing_word = played < 4 ? fifo->internalSample << (8 * played) : 0;
    q->known = 1;
}

/* Where the queue's reading and writing have got to, and how many bytes of the word being played
 * are left. */
struct queue_places {
    int write;
    int read;
    int remaining;
};

static struct queue_places
feed_queue_places(struct GBA *gba)
{
    struct GBAAudioFIFO *fifo = &gba->audio.chA;
    struct queue_places places = { fifo->fifoWrite, fifo->fifoRead, fifo->internalRemaining };
    return places;
}

/* Note what one event did to the queue: the word it took off and the byte it played, or the word
 * the copy engine put in. One event does one or the other. +sound_tick+ says the event was the
 * channel's own timer running out, which plays a sample whatever the queue holds — silence, when
 * it holds nothing. */
static void
feed_record_queue_changes(struct mgba_core *mc, struct GBA *gba, struct queue_places before, uint32_t late,
                          int sound_tick)
{
    struct GBAAudioFIFO *fifo = &gba->audio.chA;
    struct feed_queue_mirror *q = &mc->feed_queue;
    int pushed = (fifo->fifoWrite - before.write + GBA_AUDIO_FIFO_SIZE) % GBA_AUDIO_FIFO_SIZE;
    int taken = (fifo->fifoRead - before.read + GBA_AUDIO_FIFO_SIZE) % GBA_AUDIO_FIFO_SIZE;
    int played = before.remaining + (4 * taken) - fifo->internalRemaining;

    /* The queue emptied itself (its reset was written): nothing in it any more came from where
     * this thought, so start again from what is there. */
    if (played < 0 || played > 4) {
        feed_seed_queue_mirror(mc, fifo);
        return;
    }

    int first_byte = 4 - before.remaining;
    for (int k = 0; k < taken; ++k) {
        int slot = (before.read + k) % GBA_AUDIO_FIFO_SIZE;
        q->playing_from = q->from[slot];
        q->playing_word = q->word[slot];
        first_byte = 0;
    }
    for (int i = 0; i < played && first_byte + i < 4; ++i) {
        int byte = first_byte + i;
        uint32_t value = (q->playing_word >> (8 * byte)) & 0xFF;
        uint32_t from = q->playing_from ? q->playing_from + (uint32_t)byte : 0;
        feed_log_event(mc, FEED_PLAYED, from, value, late);
    }
    if (sound_tick && played == 0)
        feed_log_event(mc, FEED_SILENCE, 0, fifo->internalSample & 0xFF, late);

    if (pushed > 0) {
        int source = fifo->dmaSource;
        uint32_t next = source > 0 ? gba->memory.dma[source].nextSource : 0;
        for (int k = 0; k < pushed; ++k) {
            int slot = (before.write + k) % GBA_AUDIO_FIFO_SIZE;
            uint32_t from = next - (uint32_t)(4 * (pushed - k));
            q->from[slot] = from;
            q->word[slot] = fifo->fifo[slot];
            feed_log_event(mc, FEED_FETCHED, from, fifo->fifo[slot], late);
        }
    }
}

/* The emulator's own functions for the four timers and the copy engine, which the wrappers below
 * call. They are the same functions for every cartridge, so one copy serves every core: two cores
 * starting a feed at once on two threads write the same value here, which is why there is no lock. */
typedef void (*timing_callback)(struct mTiming *, void *, uint32_t);
static timing_callback s_feed_timer_callback[4];
static timing_callback s_feed_dma_callback;

/* Run one of the emulator's event functions, noting what it did to the queue when the core this
 * thread is running is recording a feed (see s_logging_core). +timer+ is which timer the event is,
 * or -1 for the copy engine. */
static void
feed_run_event_recorded(timing_callback original, int timer, struct mTiming *timing, void *context, uint32_t late)
{
    struct mgba_core *mc = s_logging_core;
    if (!mc || !mc->feed_log.recording) {
        original(timing, context, late);
        return;
    }
    struct GBA *gba = (struct GBA *)mc->core->board;
    struct queue_places before = feed_queue_places(gba);
    original(timing, context, late);
    /* The test the emulator's own timer makes before it plays channel A (GBATimerUpdate). A channel
     * clocked by a timer that counts another's overflows plays inside that one's event, and its
     * silences are not noted; the framework clocks its sound by timer 0 directly. */
    int sound_tick = gba->audio.enable && (gba->audio.chALeft || gba->audio.chARight) &&
                     timer == (gba->audio.chATimer ? 1 : 0);
    feed_record_queue_changes(mc, gba, before, late, sound_tick);
}

static void feed_timer0(struct mTiming *t, void *c, uint32_t l) { feed_run_event_recorded(s_feed_timer_callback[0], 0, t, c, l); }
static void feed_timer1(struct mTiming *t, void *c, uint32_t l) { feed_run_event_recorded(s_feed_timer_callback[1], 1, t, c, l); }
static void feed_timer2(struct mTiming *t, void *c, uint32_t l) { feed_run_event_recorded(s_feed_timer_callback[2], 2, t, c, l); }
static void feed_timer3(struct mTiming *t, void *c, uint32_t l) { feed_run_event_recorded(s_feed_timer_callback[3], 3, t, c, l); }
static void feed_dma(struct mTiming *t, void *c, uint32_t l) { feed_run_event_recorded(s_feed_dma_callback, -1, t, c, l); }

static const timing_callback FEED_TIMER_WRAPPERS[4] = { feed_timer0, feed_timer1, feed_timer2, feed_timer3 };

/* Put the wrappers in place of the emulator's functions, or the emulator's back. */
static void
feed_wrap_events(struct GBA *gba, int wrap)
{
    for (int i = 0; i < 4; ++i) {
        struct mTimingEvent *event = &gba->timers[i].event;
        if (wrap && event->callback != FEED_TIMER_WRAPPERS[i]) {
            s_feed_timer_callback[i] = event->callback;
            event->callback = FEED_TIMER_WRAPPERS[i];
        } else if (!wrap && event->callback == FEED_TIMER_WRAPPERS[i]) {
            event->callback = s_feed_timer_callback[i];
        }
    }
    struct mTimingEvent *dma = &gba->memory.dmaEvent;
    if (wrap && dma->callback != feed_dma) {
        s_feed_dma_callback = dma->callback;
        dma->callback = feed_dma;
    } else if (!wrap && dma->callback == feed_dma) {
        dma->callback = s_feed_dma_callback;
    }
}

/* Core#sound_feed_start — record what recorded-sound channel A is fed and plays, from now until
 * Core#sound_feed_finish, over the frames Core#run_frame runs between. It carries on from the last
 * feed only when nothing has run since that one stopped; otherwise the queue's words are of
 * unknown origin again. GBA-only. */
static VALUE
mgba_core_sound_feed_start(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA)
        rb_raise(rb_eRuntimeError, "sound_feed is GBA-only");

    struct GBA *gba = (struct GBA *)mc->core->board;
    if (!mc->feed_queue.known || mc->feed_queue.stopped_at != mTimingGlobalTime(&gba->timing))
        feed_seed_queue_mirror(mc, &gba->audio.chA);
    mc->feed_log.count = 0;
    mc->feed_log.cut_short = 0;
    mc->feed_log.recording = 1;
    feed_wrap_events(gba, 1);
    return Qnil;
}

/* Core#sound_feed_finish — stop recording, and hand back what was seen as a Hash:
 *
 *   :played    [time, line, from, value, late] for each sample played: the emulator's clock in
 *              cycles when it got to the sample, the screen's line, the address the byte came
 *              from, the byte, signed, and how many cycles after the timer ran out it got there;
 *              silence played from an empty queue has nil for its address
 *   :fetched   [time, line, from, word, late] for each word the copy engine put in the queue
 *   :cut_short true when the list could not grow and some of it went unwritten */
static VALUE
mgba_core_sound_feed_finish(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    struct GBA *gba = (struct GBA *)mc->core->board;
    feed_wrap_events(gba, 0);
    mc->feed_log.recording = 0;
    mc->feed_queue.stopped_at = mTimingGlobalTime(&gba->timing);

    VALUE played = rb_ary_new();
    VALUE fetched = rb_ary_new();
    for (size_t i = 0; i < mc->feed_log.count; ++i) {
        const struct feed_event *e = &mc->feed_log.events[i];
        VALUE entry = rb_ary_new_capa(5);
        rb_ary_push(entry, ULL2NUM(e->at));
        rb_ary_push(entry, INT2NUM(e->line));
        rb_ary_push(entry, e->kind == FEED_SILENCE ? Qnil : UINT2NUM(e->from));
        if (e->kind == FEED_FETCHED) {
            rb_ary_push(entry, UINT2NUM(e->value));
            rb_ary_push(entry, UINT2NUM(e->late));
            rb_ary_push(fetched, entry);
        } else {
            rb_ary_push(entry, INT2NUM((int8_t)e->value));
            rb_ary_push(entry, UINT2NUM(e->late));
            rb_ary_push(played, entry);
        }
    }
    free(mc->feed_log.events);
    mc->feed_log.events = NULL;
    mc->feed_log.count = 0;
    mc->feed_log.room = 0;

    VALUE result = rb_hash_new();
    rb_hash_aset(result, ID2SYM(rb_intern("played")), played);
    rb_hash_aset(result, ID2SYM(rb_intern("fetched")), fetched);
    rb_hash_aset(result, ID2SYM(rb_intern("cut_short")), mc->feed_log.cut_short ? Qtrue : Qfalse);
    return result;
}

/* Core#registers — what the processor holds right now, as a Hash: :r0 through
 * :r14, :pc and :cpsr.
 *
 * :pc is the address of the instruction that runs NEXT (see executing_pc), not
 * the raw r15, which is ahead of it by the processor's prefetch. That is the
 * address a caller stopped at, and the one a disassembly lists. The raw r15 is
 * left out on purpose: two numbers for the one register is how somebody reads
 * the wrong one. GBA-only. */
static VALUE
mgba_core_registers(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA)
        rb_raise(rb_eRuntimeError, "registers is GBA-only");
    struct ARMCore *cpu = ((struct GBA *)mc->core->board)->cpu;

    VALUE out = rb_hash_new();
    char name[4];
    for (int i = 0; i < 15; ++i) {
        snprintf(name, sizeof(name), "r%d", i);
        rb_hash_aset(out, ID2SYM(rb_intern(name)), UINT2NUM((uint32_t)cpu->gprs[i]));
    }
    rb_hash_aset(out, ID2SYM(rb_intern("pc")), UINT2NUM(executing_pc(cpu)));
    rb_hash_aset(out, ID2SYM(rb_intern("cpsr")), UINT2NUM((uint32_t)cpu->cpsr.packed));
    return out;
}

/* Core#wave_rate — the pitch the wave voice is playing at, as the 11-bit rate a
 * game writes to SOUND3CNT_X.
 *
 * NOT READ OFF THE REGISTER, because on the console it cannot be: those eleven
 * bits are write-only, and reading SOUND3CNT_X gives back the looping bit and
 * nothing else. mGBA keeps that faithfully — the write hands the whole value to
 * the sound circuit and keeps only bit 14 for anybody reading — so a game that
 * really is playing the right note reads back as rate 0. The sound circuit's own
 * copy is the rate it is actually sounding, which is the thing worth asking about.
 * GBA-only. */
static VALUE
mgba_core_wave_rate(VALUE self)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA)
        rb_raise(rb_eRuntimeError, "wave_rate is GBA-only");
    struct GBA *gba = (struct GBA *)mc->core->board;
    return INT2NUM(gba->audio.psg.ch3.rate);
}

/* Core#run_until(address, limit) — run one instruction at a time until the
 * next one to run is at +address+, and stop there without running it. True
 * when it got there; false when +limit+ instructions went by first.
 *
 * In C rather than a Ruby loop over #step because the address a caller wants
 * is often a frame or more away, which is a quarter of a million steps, and a
 * trip into Ruby for each one is most of the wait.
 *
 * A sleeping processor still counts: a step while it waits for the screen jumps
 * to whatever is due next, so a game that sleeps between frames reaches its
 * next frame's code in a handful of steps rather than never. GBA-only. */
static VALUE
mgba_core_run_until(VALUE self, VALUE rb_address, VALUE rb_limit)
{
    struct mgba_core *mc = get_mgba_core(self);
    if (mc->core->platform(mc->core) != mPLATFORM_GBA)
        rb_raise(rb_eRuntimeError, "run_until is GBA-only");
    struct mCore *core = mc->core;
    struct ARMCore *cpu = ((struct GBA *)core->board)->cpu;

    uint32_t address = NUM2UINT(rb_address);
    long limit = NUM2LONG(rb_limit);
    for (long i = 0; i < limit; ++i) {
        if (!cpu->halted && executing_pc(cpu) == address)
            return Qtrue;
        core->step(core);
    }
    return (!cpu->halted && executing_pc(cpu) == address) ? Qtrue : Qfalse;
}

#ifdef RUBY_GBA_EMULATOR_RCHEEVOS
/* --------------------------------------------------------- */
/* RubyGBAEmulator::RARuntime — thin wrapper around rc_runtime_t   */
/*                    (RetroAchievements/rcheevos)           */
/*                                                           */
/* Compiled in only when RUBY_GBA_EMULATOR_RCHEEVOS is defined and  */
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
 * clear it after.  That static is per thread, so two cartridges checking
 * at once each see their own. */
typedef struct {
    uint32_t ids[256];
    int      count;
} ra_frame_ctx_t;

/* Per thread, for the reason written out beside s_logging_core: two cartridges checking
 * achievements at once would otherwise share this, and the comment above once said Ruby's
 * lock kept everything to one at a time, which stopped being true. */
static GEMBA_PER_THREAD ra_frame_ctx_t *s_ra_frame_ctx = NULL;

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
    .wrap_struct_name = "RubyGBAEmulator::RARuntime",
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
#endif /* RUBY_GBA_EMULATOR_RCHEEVOS */

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
/* RubyGBAEmulator.gba_bios_checksum(bytes)                  */
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
Init_ruby_gba_emulator_ext(void)
{
    /* THIS EXTENSION MAY BE CALLED FROM A RACTOR, so a game can verify several cartridges
     * at once without one of them being able to disturb another.
     *
     * Ruby shuts extensions out of Ractors by default, and this line is the only way back
     * in. It is an ASSERTION, not a check: once it is made Ruby stops protecting anything
     * here, so what earns it is below and in the audit note beside build_gba_color_lut.
     * Methods defined after this call are the ones it covers. */
    rb_ext_ractor_safe(true);

    /* Install no-op logger before any mGBA calls */
    mLogSetDefaultLogger(&s_recording_logger);

    /* Work the colour table out now rather than the first time a frame wants it. Two
     * Ractors rendering at once would otherwise both find it unbuilt and both build it,
     * over each other. It is 128KB and a few milliseconds, once. */
    build_gba_color_lut();

    /* RubyGBAEmulator module */
    mRubyGBAEmulator = rb_define_module("RubyGBAEmulator");

    /* Which source this build came from, worked out by extconf.rb. The Ruby side compares it
     * with the source beside it as it loads, so a checkout that pulled new code and did not
     * rebuild is told so rather than handed a build that is missing what the Ruby asks for.
     * Frozen, so a Ractor may read it. */
    rb_define_const(mRubyGBAEmulator, "BUILT_FROM",
                    rb_obj_freeze(rb_str_new_cstr(RUBY_GBA_EMULATOR_BUILT_FROM)));

    /* RubyGBAEmulator::Core class */
    cCore = rb_define_class_under(mRubyGBAEmulator, "Core", rb_cObject);
    rb_define_alloc_func(cCore, mgba_core_alloc);

    rb_define_method(cCore, "initialize",  mgba_core_initialize, -1);
    rb_define_method(cCore, "pad_reads",   mgba_core_pad_reads, 0);
    rb_define_method(cCore, "sprites",     mgba_core_sprites, 0);
    rb_define_method(cCore, "palette",     mgba_core_palette, 0);
    rb_define_method(cCore, "scroll",      mgba_core_scroll, 1);
    rb_define_method(cCore, "video_layers",   mgba_core_video_layers, 0);
    rb_define_method(cCore, "audio_channels", mgba_core_audio_channels, 0);
    rb_define_method(cCore, "enable_video_layer",   mgba_core_enable_video_layer, 2);
    rb_define_method(cCore, "addresses_holding",   mgba_core_addresses_holding, 1);
    rb_define_method(cCore, "narrow_to",           mgba_core_narrow_to, 2);
    /* The ways a search can be narrowed, so the Ruby side names them rather than knowing
     * which number the emulator gives each. */
    rb_define_const(cCore, "HOLDS_THIS",   INT2NUM(mCORE_MEMORY_SEARCH_EQUAL));
    rb_define_const(cCore, "WENT_UP",      INT2NUM(mCORE_MEMORY_SEARCH_DELTA_POSITIVE));
    rb_define_const(cCore, "WENT_DOWN",    INT2NUM(mCORE_MEMORY_SEARCH_DELTA_NEGATIVE));
    rb_define_const(cCore, "MOVED_AT_ALL", INT2NUM(mCORE_MEMORY_SEARCH_DELTA_ANY));
    rb_define_method(cCore, "watch_display",        mgba_core_watch_display, 0);
    rb_define_method(cCore, "take_display_writes",  mgba_core_take_display_writes, 0);
    rb_define_method(cCore, "display_writes_missed", mgba_core_display_writes_missed, 0);
    rb_define_method(cCore, "enable_audio_channel", mgba_core_enable_audio_channel, 2);
    rb_define_method(cCore, "watch",       mgba_core_watch, 1);
    rb_define_method(cCore, "watch_arrivals", mgba_core_watch_arrivals, 1);
    rb_define_method(cCore, "arrivals",    mgba_core_arrivals, 0);
    rb_define_method(cCore, "take_changes",   mgba_core_take_changes, 0);
    rb_define_method(cCore, "changes_missed", mgba_core_changes_missed, 0);
    rb_define_method(cCore, "crashed?",    mgba_core_crashed_p, 0);
    rb_define_method(cCore, "complaints",  mgba_core_complaints, 0);
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
    rb_define_method(cCore, "state_file_identity", mgba_core_state_file_identity, 1);
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
    rb_define_method(cCore, "bus_read_bytes", mgba_core_bus_read_bytes, 2);
    rb_define_method(cCore, "bus_write32",  mgba_core_bus_write32, 2);
    rb_define_method(cCore, "step",          mgba_core_step, 0);
    rb_define_method(cCore, "global_cycles", mgba_core_global_cycles, 0);
    rb_define_method(cCore, "frame_cycles",  mgba_core_frame_cycles, 0);
    rb_define_method(cCore, "cpu_cycles",    mgba_core_cpu_cycles, 0);
    rb_define_method(cCore, "cpu_halted?",   mgba_core_cpu_halted_p, 0);
    rb_define_method(cCore, "measure_frame_busy_cycles", mgba_core_measure_frame_busy_cycles, 0);
    rb_define_method(cCore, "measure_frame_work", mgba_core_measure_frame_work, 0);
    rb_define_method(cCore, "profile",       mgba_core_profile, 2);
    rb_define_method(cCore, "profile_gb",    mgba_core_profile_gb, 1);
    rb_define_method(cCore, "sound_feed_start",  mgba_core_sound_feed_start, 0);
    rb_define_method(cCore, "sound_feed_finish", mgba_core_sound_feed_finish, 0);
    rb_define_method(cCore, "registers",     mgba_core_registers, 0);
    rb_define_method(cCore, "wave_rate",     mgba_core_wave_rate, 0);
    rb_define_method(cCore, "run_until",     mgba_core_run_until, 2);

    /* BIOS checksum utility */
    rb_define_module_function(mRubyGBAEmulator, "gba_bios_checksum", mgba_gba_bios_checksum, 1);
    rb_define_const(mRubyGBAEmulator, "GBA_BIOS_CHECKSUM",    UINT2NUM(GBA_BIOS_CHECKSUM));
    rb_define_const(mRubyGBAEmulator, "GBA_DS_BIOS_CHECKSUM", UINT2NUM(GBA_DS_BIOS_CHECKSUM));

    /* GBA key constants (bitmask values for set_keys) */
    rb_define_const(mRubyGBAEmulator, "KEY_A",      INT2NUM(1 << GEMBA_KEY_A));
    rb_define_const(mRubyGBAEmulator, "KEY_B",      INT2NUM(1 << GEMBA_KEY_B));
    rb_define_const(mRubyGBAEmulator, "KEY_SELECT", INT2NUM(1 << GEMBA_KEY_SELECT));
    rb_define_const(mRubyGBAEmulator, "KEY_START",  INT2NUM(1 << GEMBA_KEY_START));
    rb_define_const(mRubyGBAEmulator, "KEY_RIGHT",  INT2NUM(1 << GEMBA_KEY_RIGHT));
    rb_define_const(mRubyGBAEmulator, "KEY_LEFT",   INT2NUM(1 << GEMBA_KEY_LEFT));
    rb_define_const(mRubyGBAEmulator, "KEY_UP",     INT2NUM(1 << GEMBA_KEY_UP));
    rb_define_const(mRubyGBAEmulator, "KEY_DOWN",   INT2NUM(1 << GEMBA_KEY_DOWN));
    rb_define_const(mRubyGBAEmulator, "KEY_R",      INT2NUM(1 << GEMBA_KEY_R));
    rb_define_const(mRubyGBAEmulator, "KEY_L",      INT2NUM(1 << GEMBA_KEY_L));

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
    rb_define_const(mRubyGBAEmulator, "GBA_BTN_BITS", btn_bits);

    /* XOR delta for frame-diff analysis */
    rb_define_module_function(mRubyGBAEmulator, "xor_delta", mgba_xor_delta, 2);
    rb_define_module_function(mRubyGBAEmulator, "count_changed_pixels", mgba_count_changed_pixels, 1);

    /* RubyGBAEmulator::Screen — questions about a whole picture */
    VALUE mScreen = rb_define_module_under(mRubyGBAEmulator, "Screen");
    rb_define_module_function(mScreen, "colors", screen_colors, 1);
    rb_define_module_function(mScreen, "color_list", screen_color_list, 1);
    rb_define_module_function(mScreen, "only_color", screen_only_color, -1);
    rb_define_module_function(mScreen, "same?", screen_same_p, 2);
    rb_define_module_function(mScreen, "difference", screen_difference, -1);
    rb_define_module_function(mScreen, "brightness", screen_brightness, -1);

#ifdef RUBY_GBA_EMULATOR_RCHEEVOS
    /* Frozen empty array returned by RARuntime#do_frame when nothing triggered */
    ra_empty_array = rb_ary_freeze(rb_ary_new_capa(0));
    rb_gc_register_mark_object(ra_empty_array);

    /* RubyGBAEmulator::RARuntime — RA condition evaluator */
    cRARuntime = rb_define_class_under(mRubyGBAEmulator, "RARuntime", rb_cObject);
    rb_define_alloc_func(cRARuntime, ra_runtime_alloc);
    rb_define_method(cRARuntime, "activate",              ra_runtime_rb_activate,              2);
    rb_define_method(cRARuntime, "deactivate",            ra_runtime_rb_deactivate,            1);
    rb_define_method(cRARuntime, "reset_all",             ra_runtime_rb_reset_all,             0);
    rb_define_method(cRARuntime, "clear",                 ra_runtime_rb_clear,                 0);
    rb_define_method(cRARuntime, "do_frame",              ra_runtime_rb_do_frame,              1);
    rb_define_method(cRARuntime, "count",                 ra_runtime_rb_count,                 0);
    rb_define_method(cRARuntime, "activate_richpresence", ra_runtime_rb_activate_richpresence, 1);
    rb_define_method(cRARuntime, "get_richpresence",      ra_runtime_rb_get_richpresence,      1);
#endif /* RUBY_GBA_EMULATOR_RCHEEVOS */
}

/*
 * rvd_swmd.c -- software motion detection, for HALs with no IVS engine
 *
 * Ingenic's IVS does motion in the SDK; Xiongmai and Fullhan have nothing
 * rvd can bind to. This samples the sub-stream (stream1) a few times a
 * second through fs_get_frame -- the same raw path as `save raw` -- and
 * compares a coarse luma grid against a running background. Results land
 * in the same ivs_motion / ivs_motion_ts atomics the IVS thread fills, so
 * `ivs-status`, rmd and everything after it work unchanged.
 *
 * What it is built to ignore, since its results become phone alerts:
 *   - exposure steps and slow light changes: the frame-wide mean shift is
 *     taken out before cells are compared;
 *   - whole-scene changes (IR-cut / day-night switch, a light switched
 *     on, AE settling): when most of the grid changes at once the
 *     background is reset and detection rests for a moment;
 *   - single-frame flicker and noise: a cell must differ by a sensitivity
 *     threshold, enough cells must differ, and on two checks in a row.
 * Motion holds for 2 s after the last positive check, as the IVS move
 * path does.
 *
 * [motion] algorithm = soft selects it on any HAL; on a HAL without
 * ivs_create_group it is used for "move" (the default) too.
 */

#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "rvd.h"

#define SWMD_GX 16
#define SWMD_GY 12
#define SWMD_CELLS (SWMD_GX * SWMD_GY)
#define SWMD_STEP 4		   /* sample every 4th pixel, both ways */
#define SWMD_HOLD_US 2000000	   /* motion stays on this long after a hit */
#define SWMD_SETTLE_US 3000000	   /* rest after a whole-scene change */
#define SWMD_GLOBAL_PCT 50	   /* more of the grid than this = scene change */
#define SWMD_CONFIRM 2		   /* consecutive positive checks to report */

/* by sensitivity 0..4 (IVS's scale): luma difference per cell, cells */
static const int swmd_thr[5] = {20, 14, 10, 7, 5};
static const int swmd_min_cells[5] = {6, 4, 3, 2, 2};

/* One raw-frame user at a time: this thread and `save raw` share the HAL's
 * per-channel grab state. */
pthread_mutex_t rvd_raw_lock = PTHREAD_MUTEX_INITIALIZER;

int rvd_swmd_init(rvd_state_t *st)
{
	if (st->stream_count < 2 || st->streams[1].is_jpeg) {
		RSS_WARN("motion: software detection needs the sub-stream (stream1)");
		return RSS_ERR;
	}
	if (!st->ops->fs_get_frame || !st->ops->fs_release_frame) {
		RSS_WARN("motion: this HAL gives no raw frames; no software detection");
		return RSS_ERR;
	}
	int sens = rss_config_get_int(st->cfg, "motion", "sensitivity", 3);
	if (sens < 0)
		sens = 0;
	if (sens > 4)
		sens = 4;
	int iv = rss_config_get_int(st->cfg, "motion", "interval_ms", 250);
	if (iv < 100)
		iv = 100;
	if (iv > 2000)
		iv = 2000;
	atomic_store(&st->swmd_sens, sens);
	atomic_store(&st->swmd_interval_ms, iv);
	atomic_store(&st->ivs_motion, false);
	atomic_store(&st->ivs_motion_ts, 0);
	st->swmd = true;
	RSS_INFO("motion: software detection on stream1 (sensitivity %d, every %d ms)", sens,
		 iv);
	return RSS_OK;
}

/* Mean luma of each grid cell, sampled. NV12/NV21: luma plane first,
 * stride = width. */
static void swmd_cells(const uint8_t *y, int w, int h, int *out)
{
	for (int gy = 0; gy < SWMD_GY; gy++) {
		int y0 = gy * h / SWMD_GY, y1 = (gy + 1) * h / SWMD_GY;
		for (int gx = 0; gx < SWMD_GX; gx++) {
			int x0 = gx * w / SWMD_GX, x1 = (gx + 1) * w / SWMD_GX;
			unsigned sum = 0, n = 0;
			for (int yy = y0; yy < y1; yy += SWMD_STEP) {
				const uint8_t *row = y + (size_t)yy * w;
				for (int xx = x0; xx < x1; xx += SWMD_STEP) {
					sum += row[xx];
					n++;
				}
			}
			out[gy * SWMD_GX + gx] = n ? (int)(sum / n) : 0;
		}
	}
}

static int swmd_grab(rvd_state_t *st, int chn, int *cells)
{
	rss_frame_info_t info = {0};
	void *frame = NULL;
	int ret;

	pthread_mutex_lock(&rvd_raw_lock);
	RSS_HAL_CALL(st->ops, fs_set_frame_depth, st->hal_ctx, chn, 1);
	ret = RSS_HAL_CALL(st->ops, fs_get_frame, st->hal_ctx, chn, &frame, &info);
	if (ret == 0 && frame && info.virt_addr && info.width >= SWMD_GX * SWMD_STEP &&
	    info.height >= SWMD_GY * SWMD_STEP &&
	    info.size >= (uint32_t)info.width * info.height)
		swmd_cells(info.virt_addr, info.width, info.height, cells);
	else if (ret == 0)
		ret = RSS_ERR_IO;
	if (frame)
		RSS_HAL_CALL(st->ops, fs_release_frame, st->hal_ctx, chn, frame);
	RSS_HAL_CALL(st->ops, fs_set_frame_depth, st->hal_ctx, chn, 0);
	pthread_mutex_unlock(&rvd_raw_lock);
	return ret;
}

void *rvd_swmd_thread(void *arg)
{
	rvd_state_t *st = arg;
	int chn = st->streams[1].fs_chn;
	int cur[SWMD_CELLS], bg[SWMD_CELLS]; /* bg in 1/16 luma */
	bool have_bg = false;
	int hits = 0, fails = 0;
	int64_t settle_until = 0, last_hit = 0;

	RSS_INFO("motion: software detection thread started (fs %d)", chn);

	while (rss_running(st->running) && atomic_load(&st->swmd_active)) {
		usleep((useconds_t)atomic_load(&st->swmd_interval_ms) * 1000);
		if (!rss_running(st->running) || !atomic_load(&st->swmd_active))
			break;

		int ret = swmd_grab(st, chn, cur);
		if (ret != 0) {
			/* stream restarts and the first frames are expected; say
			 * so once in a while, not every check */
			if (fails++ % 40 == 0)
				RSS_DEBUG("motion: no frame from fs %d (%d)", chn, ret);
			have_bg = false;
			continue;
		}
		fails = 0;
		int64_t now = rss_timestamp_us();

		if (!have_bg) {
			for (int i = 0; i < SWMD_CELLS; i++)
				bg[i] = cur[i] << 4;
			have_bg = true;
			hits = 0;
			continue;
		}

		/* frame-wide shift (exposure, slow light) taken out first */
		int shift = 0;
		for (int i = 0; i < SWMD_CELLS; i++)
			shift += cur[i] - (bg[i] >> 4);
		shift /= SWMD_CELLS;

		int sens = atomic_load(&st->swmd_sens);
		int thr = swmd_thr[sens], changed = 0;
		bool cell_changed[SWMD_CELLS];
		for (int i = 0; i < SWMD_CELLS; i++) {
			int d = abs(cur[i] - (bg[i] >> 4) - shift);
			cell_changed[i] = d > thr;
			changed += cell_changed[i];
		}

		bool motion_now = false;
		if (changed * 100 > SWMD_GLOBAL_PCT * SWMD_CELLS) {
			/* the whole scene moved: IR-cut, a light, AE. Start over. */
			for (int i = 0; i < SWMD_CELLS; i++)
				bg[i] = cur[i] << 4;
			settle_until = now + SWMD_SETTLE_US;
			hits = 0;
			RSS_DEBUG("motion: scene change (%d/%d cells), resting", changed,
				  SWMD_CELLS);
			continue;
		}
		if (now >= settle_until)
			motion_now = changed >= swmd_min_cells[sens];

		/* background: quick where still, slow where something is, so
		 * a parked car or a moved chair fades in over ~10 s */
		for (int i = 0; i < SWMD_CELLS; i++) {
			int target = cur[i] << 4;
			bg[i] += (target - bg[i]) >> (cell_changed[i] ? 5 : 3);
		}

		hits = motion_now ? hits + 1 : 0;
		bool prev = atomic_load(&st->ivs_motion);
		if (hits >= SWMD_CONFIRM) {
			last_hit = now;
			atomic_store(&st->ivs_motion_ts, now);
			if (!prev) {
				atomic_store(&st->ivs_motion, true);
				RSS_DEBUG("motion: detected (%d cells)", changed);
			}
		} else if (prev && now - last_hit > SWMD_HOLD_US) {
			atomic_store(&st->ivs_motion, false);
			RSS_DEBUG("motion: stopped");
		}
	}

	atomic_store(&st->ivs_motion, false);
	RSS_INFO("motion: software detection thread exiting");
	return NULL;
}

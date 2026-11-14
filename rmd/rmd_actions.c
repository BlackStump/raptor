/*
 * rmd_actions.c -- Motion event actions (GPIO, recording trigger)
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#include "rmd.h"

/* ── GPIO via sysfs ── */

/*
 * The sysfs directory of an exported pin. Most kernels name it gpio<N>; the
 * Fullhan FH885xV200 kernel names it GPIO<N> (measured on a PB4, 2026-11-05:
 * `echo 1 > export` makes /sys/class/gpio/GPIO1). Prefer the lower-case name,
 * use the upper-case one only when it is the one that exists.
 */
static void gpio_path(char *buf, size_t size, int pin, const char *leaf)
{
	char alt[64];

	snprintf(buf, size, "/sys/class/gpio/gpio%d/%s", pin, leaf);
	if (access(buf, F_OK) == 0)
		return;
	snprintf(alt, sizeof(alt), "/sys/class/gpio/GPIO%d/%s", pin, leaf);
	if (access(alt, F_OK) == 0)
		snprintf(buf, size, "%s", alt);
}


static int gpio_export(int pin)
{
	int fd = open("/sys/class/gpio/export", O_WRONLY);
	if (fd < 0)
		return -1;
	char buf[16];
	int len = snprintf(buf, sizeof(buf), "%d", pin);
	if (write(fd, buf, len) < 0)
		RSS_WARN("gpio export %d: write failed: %s", pin, strerror(errno));
	close(fd);

	/* Set direction to output */
	char path[64];
	gpio_path(path, sizeof(path), pin, "direction");
	fd = open(path, O_WRONLY);
	if (fd < 0)
		return -1;
	if (write(fd, "out", 3) < 0)
		RSS_WARN("gpio %d direction: write failed: %s", pin, strerror(errno));
	close(fd);
	return 0;
}

static int gpio_set_value(int pin, int value)
{
	char path[64];
	gpio_path(path, sizeof(path), pin, "value");
	int fd = open(path, O_WRONLY);
	if (fd < 0)
		return -1;
	if (write(fd, value ? "1" : "0", 1) < 0)
		RSS_WARN("gpio %d set: write failed: %s", pin, strerror(errno));
	close(fd);
	return 0;
}

void rmd_gpio_init(rmd_ctx_t *ctx)
{
	if (ctx->settings.gpio_pin < 0)
		return;
	if (gpio_export(ctx->settings.gpio_pin) == 0)
		RSS_DEBUG("GPIO %d initialized for motion output", ctx->settings.gpio_pin);
	else
		RSS_WARN("GPIO %d export failed (may already be exported)", ctx->settings.gpio_pin);
}

void rmd_gpio_set(rmd_ctx_t *ctx, bool active)
{
	if (ctx->settings.gpio_pin < 0)
		return;
	gpio_set_value(ctx->settings.gpio_pin, active ? 1 : 0);
	RSS_DEBUG("GPIO %d = %d", ctx->settings.gpio_pin, active ? 1 : 0);
}

/* ── Event file ──
 *
 * [motion] event_file: created when motion starts, removed when the
 * cooldown ends. onvif_notify_server watches its directory (inotify) and
 * turns create/delete into ONVIF motion events; anything else can watch
 * it the same way. The directory is made if missing (one level).
 */
void rmd_event_file_set(rmd_ctx_t *ctx, bool active)
{
	const char *f = ctx->settings.event_file;
	if (!f[0])
		return;
	if (!active) {
		if (unlink(f) == 0)
			RSS_DEBUG("event file %s removed", f);
		return;
	}
	int fd = open(f, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0 && errno == ENOENT) {
		char dir[128];
		rss_strlcpy(dir, f, sizeof(dir));
		char *slash = strrchr(dir, '/');
		if (slash && slash != dir) {
			*slash = '\0';
			mkdir(dir, 0755);
			fd = open(f, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
		}
	}
	if (fd < 0) {
		RSS_WARN("event file %s: %s", f, strerror(errno));
		return;
	}
	close(fd);
	RSS_DEBUG("event file %s created", f);
}

/* ── Recording trigger via RMR control socket ── */

int rmd_trigger_recording(rmd_ctx_t *ctx, bool start)
{
	(void)ctx;
	char resp[128];
	int ret = rss_ctrl_cmd(RSS_RUN_DIR "/rmr.sock", start ? "start" : "stop", resp,
			       sizeof(resp), 2000);
	if (ret < 0)
		RSS_WARN("recording %s command failed (RMR not running?)",
			 start ? "start" : "stop");
	else
		RSS_INFO("recording %s", start ? "started" : "stopped");
	return ret;
}

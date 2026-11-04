# Raptor Streaming System -- top-level build
#
# Usage:
#   make PLATFORM=T31 CROSS_COMPILE=mipsel-linux-
#   make PLATFORM=T31 CROSS_COMPILE=mipsel-linux- rvd ringdump
#   make clean
#
# Required:
#   PLATFORM       - Target SoC:
#                      Ingenic   - T10, T20, T21, T23, T30, T31, T32, T33, T40, T41, A1
#                      SigmaStar - INFINITY6E, INFINITY6B0, INFINITY6C
#                      HiSilicon - HI3516EV200, HI3516EV300
#   CROSS_COMPILE  - Cross-compiler prefix
#
ifeq ($(filter clean distclean build,$(MAKECMDGOALS)),)
ifndef PLATFORM
$(error PLATFORM not set. Use: make PLATFORM=T31 CROSS_COMPILE=mipsel-linux-)
endif
endif

# Sibling repos
HAL_DIR    := ../raptor-hal
IPC_DIR    := ../raptor-ipc
COMMON_DIR := ../raptor-common
COMPY_DIR  := ../compy

# Vendor and architecture selection — the platform lists must stay in step with
# raptor-hal's, which now carries them in mk/sigmastar.mk and mk/hisilicon.mk
# rather than in its Makefile. Two files, one invariant: a PLATFORM listed here
# and not there builds the wrong backend.
#
# Ingenic parts link the single IMP library. SigmaStar and HiSilicon parts link
# no vendor library at all, reaching MI and HiMPP through dlopen (see
# raptor-hal/sigmastar-headers/infinity6e/i6_common.h and
# raptor-hal/src/hal_internal_hisilicon.h).
INGENIC_PLATFORMS   := T10 T20 T21 T23 T30 T31 T32 T33 T40 T41 A1
SIGMASTAR_PLATFORMS := INFINITY6E INFINITY6B0 INFINITY6C

# Split by MPP generation, because V5 is a different ABI from V4 and has its
# own backend directory (raptor-hal/src/hisi_v5). The union is what VENDOR
# keys on, and both generations are ARM soft-float, so nothing below splits.
#
# HI3516CV610 names the ABI, not the die: OpenIPC builds one MPP for the whole
# hi3516cv6xx family and it reports "HI3516CV610_MPP_V1.0.2.0 B051" on a CV608
# too, so the die travels as SOC_MODEL instead. Keep this in step with
# raptor-hal/mk/hisilicon.mk.
HISI_GEN4_PLATFORMS := HI3516EV200 HI3516EV300
HISI_GEN5_PLATFORMS := HI3516CV610
HISILICON_PLATFORMS := $(strip $(HISI_GEN4_PLATFORMS) $(HISI_GEN5_PLATFORMS))

# Fullhan FH885xV200: ARMv6 (arm1176jzf-s), soft-float, uClibc-built vendor
# libraries reached through dlopen. Keep in step with raptor-hal/mk/fullhan.mk.
FULLHAN_PLATFORMS := FH8852V200

VALID_PLATFORMS := $(INGENIC_PLATFORMS) $(SIGMASTAR_PLATFORMS) $(HISILICON_PLATFORMS) \
                   $(FULLHAN_PLATFORMS)

# Which config/sensors/ subdirectory, if any, this platform's image needs
# installed. Empty for every generation whose vendor image already ships
# /etc/sensors; see the install rule for what makes gen5 different.
HAL_SENSOR_DIR := $(if $(filter $(PLATFORM),$(HISI_GEN5_PLATFORMS)),hisi_v5)

# No default clause. The old two-way form treated every unlisted PLATFORM as
# Ingenic, so a typo built a MIPS-flavoured configuration for an ARM part and
# said nothing until the link failed somewhere unhelpful.
VENDOR := $(strip \
  $(if $(filter $(PLATFORM),$(INGENIC_PLATFORMS)),ingenic) \
  $(if $(filter $(PLATFORM),$(SIGMASTAR_PLATFORMS)),sigmastar) \
  $(if $(filter $(PLATFORM),$(HISILICON_PLATFORMS)),hisilicon) \
  $(if $(filter $(PLATFORM),$(FULLHAN_PLATFORMS)),fullhan))

ARCH := $(strip \
  $(if $(filter $(PLATFORM),$(INGENIC_PLATFORMS)),mips) \
  $(if $(filter $(PLATFORM),$(SIGMASTAR_PLATFORMS) $(HISILICON_PLATFORMS) $(FULLHAN_PLATFORMS)),arm))

ifeq ($(filter clean distclean build,$(MAKECMDGOALS)),)
ifeq ($(VENDOR),)
$(error Invalid PLATFORM=$(PLATFORM). Valid: $(VALID_PLATFORMS))
endif
endif

# Toolchain
CC     := $(CROSS_COMPILE)gcc
AR     := $(CROSS_COMPILE)ar
STRIP  := $(CROSS_COMPILE)strip

# Common flags for all daemons
EXTRA_CFLAGS ?=
CFLAGS := -Wall -Wextra -Werror
CFLAGS += -std=gnu11 -D_GNU_SOURCE
CFLAGS += -ffunction-sections -fdata-sections
CFLAGS += -DPLATFORM_$(PLATFORM)
# SOC_MODEL is the part; PLATFORM is only its family, and some facts do not
# survive that generalisation -- ssc333, ssc335 and ssc337 are all
# INFINITY6B0 and are rated 3M@20, 3M@30 and 5M@20 respectively. The part is
# not readable at runtime (the chip ID is family-wide: ipctool reports
# SSC33X for all three), so it has to arrive from the build.
#
# Optional. A build that names no model gets no -DSOC_MODEL_*, and the caps
# tables leave the per-part fields at 0, which reads as "unmeasured" and
# clamps nothing.
ifneq ($(SOC_MODEL),)
CFLAGS += -DSOC_MODEL_$(shell echo $(SOC_MODEL) | tr '[:lower:]' '[:upper:]')
endif
CFLAGS += -I$(CURDIR)/$(HAL_DIR)/include
CFLAGS += -I$(CURDIR)/$(IPC_DIR)/include
CFLAGS += -I$(CURDIR)/$(COMMON_DIR)/include
CFLAGS += -I$(CURDIR)/$(COMMON_DIR)/third_party/monocypher

# xburst2 (T40/T41/A1) toolchain uses -mfp64 ABI by default.
# Ensure largefile support matches buildroot target flags.
ifneq ($(filter T40 T41 A1,$(PLATFORM)),)
CFLAGS += -D_LARGEFILE_SOURCE -D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64
endif

CFLAGS += $(EXTRA_CFLAGS)

# Build info — generate a tiny .o with string constants that each daemon links.
# Uses $(shell) so it runs at Makefile parse time, before any targets.
RSS_BUILD_HASH ?= $(shell git -C $(CURDIR) rev-parse --short HEAD 2>/dev/null || echo unknown)
RSS_BUILD_TIME ?= $(shell date -u '+%Y-%m-%dT%H:%M:%SZ')
RSS_BUILD_OBJ := $(CURDIR)/rss_build_info.o
$(shell printf 'const char *rss_build_hash = "%s";\nconst char *rss_build_time = "%s";\nconst char *rss_build_platform = "%s";\n' \
	'$(RSS_BUILD_HASH)' '$(RSS_BUILD_TIME)' '$(PLATFORM)' > $(CURDIR)/rss_build_info.c)
$(RSS_BUILD_OBJ): $(CURDIR)/rss_build_info.c $(CONFIG_STAMP)
	@echo "  CC      rss_build_info.c"
	$(Q)$(CC) $(CFLAGS) -c $< -o $@

# Every daemon links this object for the build banner
RSS_BUILD_LIBS := $(RSS_BUILD_OBJ)

ifeq ($(DEBUG),1)
CFLAGS += -O0 -g
else
# LTO does the whole-program dead-code elimination that lets daemons drop unused
# library code (e.g. libmov write-side funcs in rfs). At -O0 it doesn't, so debug
# builds omit -flto and rely on -ffunction-sections + -Wl,--gc-sections instead.
CFLAGS += -Os -flto -fno-asynchronous-unwind-tables -fmerge-all-constants -fno-ident
endif

ifeq ($(AUDIO_EFFECTS),1)
CFLAGS += -DRAPTOR_AUDIO_EFFECTS
endif

ifeq ($(V4L2_OPENIMP),1)
CFLAGS += -DRAPTOR_V4L2_OPENIMP
endif

ifeq ($(AAC),1)
CFLAGS += -DRAPTOR_AAC
LDFLAGS_AAC_ENC := -lfaac
LDFLAGS_AAC_DEC := -lhelix-aac
endif

ifeq ($(MP3),1)
CFLAGS += -DRAPTOR_MP3 -DARDUINO
LDFLAGS_MP3 := -lhelix-mp3
endif

ifeq ($(OPUS),1)
CFLAGS += -DRAPTOR_OPUS
LDFLAGS_OPUS := -lopus
endif

ifeq ($(WEBTORRENT),1)
CFLAGS += -DRAPTOR_WEBTORRENT
endif

ifeq ($(V),1)
Q :=
else
Q := @
endif

# Compy include paths (for RSD only).
# The build dir is arch-suffixed because compy is a separate CMake project
# built per target; build-standalone.sh overrides COMPY_BUILD/LIB_COMPY_FILE
# outright, so this only sets the default for in-tree builds.
COMPY_BUILD  ?= $(CURDIR)/$(COMPY_DIR)/build-$(ARCH)
COMPY_CFLAGS := -I$(CURDIR)/$(COMPY_DIR)/include \
                -I$(COMPY_BUILD)/_deps/slice99-src \
                -I$(COMPY_BUILD)/_deps/datatype99-src \
                -I$(COMPY_BUILD)/_deps/interface99-src \
                -I$(COMPY_BUILD)/_deps/metalang99-src/include

ifeq ($(TLS),1)
COMPY_CFLAGS += -DCOMPY_HAS_TLS
LDFLAGS_TLS := -lmbedtls -lmbedx509 -lmbedcrypto
endif

# RMQ links libmosquitto rather than carrying an MQTT codec. Whether TLS is
# available is a property of how that library was built, not of TLS above.
LDFLAGS_MOSQUITTO ?= -lmosquitto

# Which platform a compiled object was built for is invisible to Make: PLATFORM
# and SOC_MODEL reach the compiler only as -D flags. Switching platform in a
# tree that has already been built therefore leaves every .o looking up to date
# while it is wrong. Record the settings that select code, hand the record down
# to the sub-makes, and rewrite it only when it differs -- a same-platform
# rebuild stays incremental, a switch rebuilds what depends on it. The rule that
# maintains the file is below `all', so that it cannot become the default goal.
BUILD_CONFIG := PLATFORM=$(PLATFORM) SOC_MODEL=$(SOC_MODEL) DEBUG=$(DEBUG) \
                TLS=$(TLS) CC=$(CC)
CONFIG_STAMP := $(CURDIR)/.build-config

# Library file paths (for Make dependencies and build triggers)
#
# These are prerequisites of the daemon targets below, but those targets are
# .PHONY, so all a rebuilt library does here is re-enter the sub-make. The
# sub-make is the one that decides whether to link, and it only ever compared
# the binary against its own objects -- so a library that changed under an
# unchanged daemon left the daemon alone, and the stale binary kept whatever
# the archive held when it was last linked.
#
# That is a silent wrong answer rather than a slow build. The HAL archive is
# per-platform: everything it knows about which SoC it is compiled for arrives
# as -DPLATFORM_* and -DSOC_MODEL_* at compile time. Build the HAL for one
# family and link a daemon that was last built against another, and the daemon
# runs a board with the wrong chip's port ceilings and the wrong part's encoder
# ratings, reporting the platform it thinks it is the whole time. On an SSC333
# that produced /snap.jpg frames stitched out of VPE strips -- port 2 accepting
# a 2304-wide clone its scaler tops out at 1920 short of -- for a HAL that had
# last been compiled as INFINITY6E.
#
# So each daemon Makefile puts the file-valued half of its $(LIBS) on the
# prerequisite line (LIB_DEPS), which is what makes the link depend on what it
# actually links.
LIB_HAL_VIDEO_FILE ?= $(CURDIR)/$(HAL_DIR)/libraptor_hal_video.a
LIB_HAL_AUDIO_FILE ?= $(CURDIR)/$(HAL_DIR)/libraptor_hal_audio.a
LIB_IPC_FILE    ?= $(CURDIR)/$(IPC_DIR)/librss_ipc.so
LIB_COMMON_FILE ?= $(CURDIR)/$(COMMON_DIR)/librss_common.so
LIB_COMPY_FILE  ?= $(COMPY_BUILD)/libcompy.a

# Library link flags (for linker command line)
LIB_HAL_VIDEO ?= $(LIB_HAL_VIDEO_FILE)
LIB_HAL_AUDIO ?= $(LIB_HAL_AUDIO_FILE)
LIB_IPC    ?= -L$(CURDIR)/$(IPC_DIR) -lrss_ipc
LIB_COMMON ?= -L$(CURDIR)/$(COMMON_DIR) -lrss_common
LIB_COMPY  ?= $(LIB_COMPY_FILE)

# TLS helper (compiled separately, only linked by daemons that need it).
# Source is in raptor-common (standalone) or sysroot (buildroot).
# Gated on TLS=1: without mbedtls in the sysroot the compile fails,
# and rhd builds HTTP-only (its sources guard on RSS_HAS_TLS).
ifeq ($(TLS),1)
RSS_TLS_SRC := $(firstword $(wildcard $(CURDIR)/$(COMMON_DIR)/src/rss_tls.c) \
                           $(wildcard $(SYSROOT)/usr/share/raptor-common/rss_tls.c))
RSS_TLS_OBJ := $(CURDIR)/rss_tls.o
RSS_TLS_CFLAGS := -DRSS_HAS_TLS
ifneq ($(RSS_TLS_SRC),)
$(RSS_TLS_OBJ): $(RSS_TLS_SRC) $(CONFIG_STAMP)
	@echo "  CC      rss_tls.c"
	$(Q)$(CC) $(CFLAGS) -c $< -o $@
endif
else
RSS_TLS_OBJ :=
RSS_TLS_CFLAGS :=
endif

# Sysroot for finding shared libs (set by Buildroot or manually)
SYSROOT ?=
ifneq ($(SYSROOT),)
LDFLAGS_SYSROOT := -L$(SYSROOT)/usr/lib -Wl,-rpath-link,$(SYSROOT)/usr/lib -Wl,-rpath-link,$(SYSROOT)/lib -Wl,--allow-shlib-undefined
else
LDFLAGS_SYSROOT :=
endif

# mDNS service discovery. libmdnsd comes from the same mdnsd package that does
# the advertising half on the camera, so linking it costs nothing on the device
# and keeps a second DNS codec out of raptor.
#
# The per-package staging directory is searched as well as the assembled
# sysroot: Buildroot's per-package mode copies a package forward only into the
# packages that declare a dependency on it, and raptor declares none, so the
# assembled sysroot can lack libmdnsd on a tree where the camera has it. Set
# MDNSD_SYSROOT explicitly to override the search.
#
# Finding nothing is not an error: rmq_mdns.c then compiles to stubs that
# report an empty network, and rmq falls back to the configured broker host.
MDNSD_SYSROOT ?= $(patsubst %/usr/include/libmdnsd/mdnsd.h,%,$(firstword \
                   $(wildcard $(SYSROOT)/usr/include/libmdnsd/mdnsd.h) \
                   $(wildcard $(SYSROOT)/../../../per-package/mdnsd*/host/*/sysroot/usr/include/libmdnsd/mdnsd.h)))

ifneq ($(MDNSD_SYSROOT),)
CFLAGS_MDNS  := -DRMQ_HAS_MDNS -I$(MDNSD_SYSROOT)/usr/include
LDFLAGS_MDNS := -L$(MDNSD_SYSROOT)/usr/lib -lmdnsd
else
CFLAGS_MDNS  :=
LDFLAGS_MDNS :=
endif

# libc shim — prefer static archive (eliminates .so from device), fall back to shared
SHIM_A := $(firstword $(wildcard $(SYSROOT)/usr/lib/libmuslshim.a $(SYSROOT)/lib/libmuslshim.a \
                                 $(SYSROOT)/usr/lib/libuclibcshim.a $(SYSROOT)/lib/libuclibcshim.a))
ifneq ($(SHIM_A),)
# Static link: pull all symbols (libimp.so resolves them from the executable)
SHIM_LIB := -Wl,--whole-archive $(SHIM_A) -Wl,--no-whole-archive -Wl,--export-dynamic
else
SHIM_LIB := $(if $(wildcard $(SYSROOT)/usr/lib/libmuslshim.so $(SYSROOT)/lib/libmuslshim.so),-lmuslshim,\
             $(if $(wildcard $(SYSROOT)/usr/lib/libuclibcshim.so $(SYSROOT)/lib/libuclibcshim.so),-luclibcshim,))
endif

# libstdc++ linkage (for JZDL, SRT, rsd-555)
ifeq ($(STATIC_STDCXX),1)
LINK_STDCXX := -Wl,-Bstatic -lstdc++ -Wl,-Bdynamic
else
LINK_STDCXX := -lstdc++
endif

# Vendor SDK libraries.
#
# SigmaStar links none of them. The MI backend reaches the SDK through dlopen
# using the vendored loaders in raptor-hal/src/star/i6_*.h, so no MI .so has
# to exist at build time and -ldl (already in LDFLAGS_HAL below) is the whole
# requirement. That is not just a licensing convenience: the MI stack is
# coupled to the device's 4.9.84 kernel, so binding at runtime to the
# libraries the device itself carries beats baking in a build-host snapshot
# of them.
#
# The symbol closure worked out for the earlier direct-link approach still
# matters, but as dlopen *ordering* rather than as -l flags. Each libmi_*.so
# declares only libc.so.6 as NEEDED and leaves every cross-library symbol
# undefined for the loader to satisfy from the global scope, so each
# dependency must be dlopen'd RTLD_GLOBAL before its consumer:
#   libcam_os_wrapper — needed by every libmi_*, which is why i6_sys.h loads
#     it before libmi_sys
#   libispalgo → libcus3a → libmi_isp — libmi_isp calls CUS3A_*, and libcus3a
#     in turn calls AeInit/DoAe/AwbInit/IspLoadIqCfg. Phase 3 must load them
#     in that order; divinus's i6c_isp.h/m6_isp.h do exactly this.
#
# Audio needs no extra library either. The G711*/g726_*/Iaa*/MI_AED_* symbols
# libmi_ai leaves undefined are declared WEAK, so they resolve to NULL rather
# than failing, and the capture path never calls them — both references take
# raw PCM and encode in software. libmi_ao is not needed at all; nothing in
# scope plays audio out.
# Keyed off VENDOR rather than written as an if/else, so that a vendor which
# links nothing needs no entry at all.
VENDOR_LIBS_ingenic := -limp -lalog
VENDOR_LIBS := $(VENDOR_LIBS_$(VENDOR))

# HiSilicon's libraries resolve part of their symbol set from the executable's
# global scope, so the daemon must export its dynamic symbols whether or not a
# libc shim is in play. Ten symbols need it, measured on a board: the three
# uClibc-ABI symbols libsecurec.so wants from a musl userland (__ctype_b,
# __fgetc_unlocked, _stdlib_mb_cur_max) and six GK_API_* forwarders that eight
# of the shipped libsns_*.so call. __ctype_b is a data relocation bound eagerly
# when libsecurec.so loads, which is why this cannot be deferred to a dlopen
# ordering. SHIM_LIB carries --export-dynamic only on the static-shim path, and
# that path depends on a shim archive being in the sysroot.
LDFLAGS_VENDOR_hisilicon := -Wl,--export-dynamic
# Fullhan's uClibc-built libraries take `mmap` (by caller-dispatched shim) and
# `__assert` from the executable; see raptor-hal/src/fhan_v2/hal_common.c.
LDFLAGS_VENDOR_fullhan := -Wl,--export-dynamic

# System libs for HAL-linked daemons
# Shim must come BEFORE the vendor SDK libs — symbols must be resolved first.
LDFLAGS_HAL := $(LDFLAGS_SYSROOT) $(SHIM_LIB) $(VENDOR_LIBS) $(LDFLAGS_VENDOR_$(VENDOR)) \
               -lpthread -lrt -lm -ldl -latomic

# IVS detection libs
ifeq ($(IVS_DETECT),1)
CFLAGS += -DIVS_DETECT
LDFLAGS_HAL += -ljzdl.m $(LINK_STDCXX)
ifeq ($(PERSONDET),1)
CFLAGS += -DPERSONDET
LDFLAGS_HAL += -lpersonDet_inf -ljzdl -Wl,--no-as-needed -lmxu_core -lmxu_imgproc -lmxu_merge -lmxu_video -Wl,--as-needed
endif
endif
LDFLAGS     := $(LDFLAGS_SYSROOT) -lpthread -lrt -latomic

# Page size: Ingenic SoCs use 4KB pages but the MIPS toolchain defaults to
# 64KB max-page-size, and mismatched alignment causes SIGBUS on musl/uclibc.
# ARM targets are 4KB too and default to a larger max-page-size, so the same
# value is correct there and additionally avoids the segment padding.
LDFLAGS_HAL += -Wl,-z,max-page-size=0x1000 -Wl,--gc-sections -Wl,--as-needed -Wl,--enable-new-dtags,-rpath,/usr/lib $(if $(DEBUG),,-flto)
LDFLAGS     += -Wl,-z,max-page-size=0x1000 -Wl,--gc-sections -Wl,--as-needed -Wl,--enable-new-dtags,-rpath,/usr/lib $(if $(DEBUG),,-flto)
# rpath-link for local builds (finding .so at link time)
LDFLAGS_HAL += -Wl,-rpath-link,$(CURDIR)/$(IPC_DIR) -Wl,-rpath-link,$(CURDIR)/$(COMMON_DIR)
LDFLAGS     += -Wl,-rpath-link,$(CURDIR)/$(IPC_DIR) -Wl,-rpath-link,$(CURDIR)/$(COMMON_DIR)
LDFLAGS     += $(EXTRA_LDFLAGS)
EXTRA_LDFLAGS ?=
LDFLAGS_HAL += $(EXTRA_LDFLAGS)
LDFLAGS     += $(EXTRA_LDFLAGS)

# live555 include paths (for rsd-555)
LIVE555_SYSROOT ?= $(SYSROOT)
LIVE555_INC := -I$(LIVE555_SYSROOT)/usr/include/liveMedia \
               -I$(LIVE555_SYSROOT)/usr/include/groupsock \
               -I$(LIVE555_SYSROOT)/usr/include/UsageEnvironment \
               -I$(LIVE555_SYSROOT)/usr/include/BasicUsageEnvironment
LIVE555_LIBS ?= $(LIVE555_SYSROOT)/usr/lib/libliveMedia.a \
                $(LIVE555_SYSROOT)/usr/lib/libgroupsock.a \
                $(LIVE555_SYSROOT)/usr/lib/libBasicUsageEnvironment.a \
                $(LIVE555_SYSROOT)/usr/lib/libUsageEnvironment.a

# Targets
DAEMONS := rvd rsd rad rhd rod ric rmr rmd rwd rwc rfs rsp rsr rsd-555 rmq rcd
TOOLS   := raptorctl ringdump rac rlatency rverify mdnsprobe

.PHONY: all clean libs $(DAEMONS) $(TOOLS) install FORCE

all: libs $(DAEMONS) $(TOOLS)

$(CONFIG_STAMP): FORCE
	$(Q)if [ ! -f $@ ] || [ "`cat $@`" != "$(BUILD_CONFIG)" ]; then \
		echo "  CONFIG  $(BUILD_CONFIG)"; \
		printf '%s' "$(BUILD_CONFIG)" > $@; \
	fi

FORCE:


# Phase 1 quick target
phase1: libs rvd ringdump raptorctl

# -- Libraries --

libs: $(LIB_HAL_VIDEO_FILE) $(LIB_HAL_AUDIO_FILE) $(LIB_IPC_FILE) $(LIB_COMMON_FILE)

# The sibling libraries are built by sub-makes, reached through a phony
# target rather than by a rule on the library files themselves.
#
# A rule whose target is the library and which carries no prerequisites runs
# only when the file is missing, so edits to a sibling's sources never reach
# the daemons here. Only the sub-make knows what its own library depends on,
# and a phony prerequisite is what hands it that decision on every build.
#
# One phony target per sibling, not one per library file: make enters a phony
# target once per run however many targets depend on it, so the raptor-hal
# sub-make cannot run twice concurrently under -j for its two archives.
#
# Each block is guarded on its sibling being present, because these rules
# describe a developer checkout, where raptor-hal, raptor-ipc and raptor-common
# sit next to this tree. A packaged build has no siblings -- each library comes
# from its own package through LIB_*_FILE pointing into the sysroot, where the
# file already exists and nothing here should try to enter a directory that is
# not there. Guarded per library rather than once for all three, because a
# mixture is legal: bisecting one library while the other two come from
# staging.
ifneq ($(wildcard $(HAL_DIR)/Makefile),)
.PHONY: build-raptor-hal
build-raptor-hal:
	@echo "  BUILD   raptor-hal"
	$(Q)$(MAKE) -C $(HAL_DIR) PLATFORM=$(PLATFORM) CROSS_COMPILE=$(CROSS_COMPILE) \
		$(if $(SOC_MODEL),SOC_MODEL=$(SOC_MODEL),) \
		$(if $(DEBUG),DEBUG=1,) \
		$(if $(filter 1,$(V4L2_OPENIMP)),V4L2_OPENIMP=1,)

$(LIB_HAL_VIDEO_FILE) $(LIB_HAL_AUDIO_FILE): build-raptor-hal
	@:
endif

ifneq ($(wildcard $(IPC_DIR)/Makefile),)
.PHONY: build-raptor-ipc
build-raptor-ipc:
	@echo "  BUILD   raptor-ipc"
	$(Q)$(MAKE) -C $(IPC_DIR) CC="$(CC)"

$(LIB_IPC_FILE): build-raptor-ipc
	@:
endif

ifneq ($(wildcard $(COMMON_DIR)/Makefile),)
.PHONY: build-raptor-common
build-raptor-common:
	@echo "  BUILD   raptor-common"
	$(Q)$(MAKE) -C $(COMMON_DIR) CC="$(CC)"

$(LIB_COMMON_FILE): build-raptor-common
	@:
endif

# -- Daemons --

rvd: $(CONFIG_STAMP) $(LIB_HAL_VIDEO_FILE) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rvd"
	$(Q)$(MAKE) -C rvd CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LIBS="$(LIB_HAL_VIDEO) $(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LIB_DEPS="$(LIB_HAL_VIDEO_FILE) $(RSS_BUILD_OBJ)" \
		LDFLAGS="$(LDFLAGS_HAL)" Q="$(Q)"

rsd: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(LIB_COMPY_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rsd"
	$(Q)$(MAKE) -C rsd CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS) $(COMPY_CFLAGS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(LIB_COMPY) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS) $(LDFLAGS_TLS) $(LDFLAGS_OPUS) $(LDFLAGS_AAC_DEC)" Q="$(Q)"

rsd-555: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rsd-555"
	$(Q)$(MAKE) -C rsd-555 CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CXX="$(CROSS_COMPILE)g++" CFLAGS="$(CFLAGS)" \
		LIVE555_INC="$(LIVE555_INC)" \
		LIVE555_LIBS="$(LIVE555_LIBS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS)" LINK_STDCXX="$(LINK_STDCXX)" Q="$(Q)"

rad: $(CONFIG_STAMP) $(LIB_HAL_AUDIO_FILE) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rad"
	$(Q)$(MAKE) -C rad CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LIBS="$(LIB_HAL_AUDIO) $(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS_HAL) $(LDFLAGS_AAC_ENC) $(LDFLAGS_OPUS)" Q="$(Q)"

# -lcrypt because rhd_api.c authenticates the configuration route against
# /etc/shadow and calls crypt(3). glibc keeps that in libcrypt and musl keeps it
# in libc, so a musl target links without it and a glibc one fails at the link
# with an undefined reference to `crypt' -- which is a build that passes on one
# board and not the other, from the same source. Naming it unconditionally is
# safe on both: a musl sysroot ships libcrypt.a as an empty archive precisely so
# that -lcrypt keeps working.
rhd: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_TLS_OBJ) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rhd"
	$(Q)$(MAKE) -C rhd CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS) $(RSS_TLS_CFLAGS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_TLS_OBJ) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS) $(LDFLAGS_TLS) -lcrypt" Q="$(Q)"

# -lm must follow -lschrift: libschrift's rasteriser calls floor, ceil and
# nextafter, and nothing else in rod pulls in libm.
rod: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rod"
	$(Q)$(MAKE) -C rod CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) -lschrift -lm $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS)" Q="$(Q)"

ric: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   ric"
	$(Q)$(MAKE) -C ric CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS) -ldl" Q="$(Q)"

rmr: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rmr"
	$(Q)$(MAKE) -C rmr CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS)" Q="$(Q)"

rmd: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rmd"
	$(Q)$(MAKE) -C rmd CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS)" Q="$(Q)"

rwd: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(LIB_COMPY_FILE) $(RSS_TLS_OBJ) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rwd"
	$(Q)$(MAKE) -C rwd CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS) $(COMPY_CFLAGS) -DMBEDTLS_ALLOW_PRIVATE_ACCESS -DRSS_HAS_TLS" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(LIB_COMPY) $(RSS_TLS_OBJ) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS) $(LDFLAGS_TLS) $(LDFLAGS_OPUS) $(LDFLAGS_AAC_DEC)" WEBTORRENT=$(WEBTORRENT) Q="$(Q)"

rwc: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rwc"
	$(Q)$(MAKE) -C rwc CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS)" Q="$(Q)"

LIBMOV_DIR := $(CURDIR)/.deps/media-server/libmov

rfs: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rfs"
	$(Q)$(MAKE) -C rfs CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" \
		CFLAGS="$(CFLAGS) -I$(CURDIR)/rad -I$(LIBMOV_DIR)/include -I$(LIBMOV_DIR)/source" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS) $(LDFLAGS_AAC_ENC) $(LDFLAGS_OPUS) $(LDFLAGS_MP3) $(LDFLAGS_AAC_DEC)" \
		RAD_DIR="$(CURDIR)/rad" LIBMOV_DIR="$(LIBMOV_DIR)" Q="$(Q)"

RSP_CFLAGS := -DRSS_HAS_TLS
RSP_LDFLAGS :=
ifeq ($(AAC),1)
RSP_CFLAGS += -DRAPTOR_AAC_ENC -DRAPTOR_AAC
RSP_LDFLAGS += $(LDFLAGS_AAC_ENC) $(LDFLAGS_AAC_DEC)
endif
ifeq ($(OPUS),1)
RSP_CFLAGS += -DRAPTOR_OPUS
RSP_LDFLAGS += $(LDFLAGS_OPUS)
endif

rsp: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(LIB_COMPY_FILE) $(RSS_TLS_OBJ) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rsp"
	$(Q)$(MAKE) -C rsp CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS) $(RSP_CFLAGS) $(COMPY_CFLAGS) -I$(CURDIR)/rmr" \
		RMR_DIR="$(CURDIR)/rmr" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(LIB_COMPY) $(RSS_TLS_OBJ) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS) $(LDFLAGS_TLS) $(RSP_LDFLAGS)" Q="$(Q)"

LDFLAGS_SRT ?= -lsrt $(LINK_STDCXX) -latomic $(LDFLAGS_TLS)
CFLAGS_SRT  ?= $(if $(SYSROOT),-I$(SYSROOT)/usr/include)

rsr: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rsr"
	$(Q)$(MAKE) -C rsr CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS) $(CFLAGS_SRT)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS) $(LDFLAGS_SRT)" Q="$(Q)"

# -lcrypt for the same reason rhd names it: rcd_passwd.c hashes the root
# password with crypt(3) when a camera is claimed, and glibc keeps that in
# libcrypt where musl keeps it in libc.
rcd: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rcd"
	$(Q)$(MAKE) -C rcd CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS) -lcrypt" Q="$(Q)"

rmq: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rmq"
	$(Q)$(MAKE) -C rmq CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS) $(CFLAGS_MDNS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS) $(LDFLAGS_MOSQUITTO) $(LDFLAGS_MDNS)" Q="$(Q)"

# -- Tools --

raptorctl: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   raptorctl"
	$(Q)$(MAKE) -C raptorctl CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS)" Q="$(Q)"

ringdump: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   ringdump"
	$(Q)$(MAKE) -C ringdump CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS)" Q="$(Q)"

rac: $(CONFIG_STAMP) $(LIB_IPC_FILE) $(LIB_COMMON_FILE) $(RSS_BUILD_OBJ)
	@echo "  BUILD   rac"
	$(Q)$(MAKE) -C rac CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LIBS="$(LIB_COMMON) $(LIB_IPC) $(RSS_BUILD_LIBS)" \
		LDFLAGS="$(LDFLAGS) $(LDFLAGS_MP3) $(LDFLAGS_AAC_DEC) $(LDFLAGS_OPUS)" Q="$(Q)"

rlatency: $(CONFIG_STAMP)
	@echo "  BUILD   rlatency"
	$(Q)$(MAKE) -C rlatency CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LDFLAGS="$(LDFLAGS)" Q="$(Q)"

rverify: $(CONFIG_STAMP) $(LIB_COMMON_FILE)
	@echo "  BUILD   rverify"
	$(Q)$(MAKE) -C rverify CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS)" \
		LIBS="$(LIB_COMMON)" LDFLAGS="$(LDFLAGS)" Q="$(Q)"

mdnsprobe: $(CONFIG_STAMP) $(LIB_COMMON_FILE)
	@echo "  BUILD   mdnsprobe"
	$(Q)$(MAKE) -C mdnsprobe CONFIG_STAMP="$(CONFIG_STAMP)" CC="$(CC)" CFLAGS="$(CFLAGS) $(CFLAGS_MDNS)" \
		LIBS="$(LIB_COMMON)" \
		LDFLAGS="$(LDFLAGS) $(LDFLAGS_MDNS)" Q="$(Q)"

# -- Collect binaries --

build:
	@mkdir -p build
	@for d in $(DAEMONS) $(TOOLS); do \
		if [ -f $$d/$$d ]; then cp $$d/$$d build/; fi; \
	done
	@echo "  Binaries collected in build/"

# -- Clean --

clean:
	@for d in $(DAEMONS) $(TOOLS); do \
		echo "  CLEAN   $$d"; \
		$(MAKE) -C $$d clean 2>/dev/null || true; \
	done
	rm -f rss_build_info.c rss_build_info.o rss_tls.o
	rm -rf build

distclean: clean
	$(MAKE) -C $(HAL_DIR) clean
	$(MAKE) -C $(IPC_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(COMMON_DIR) clean 2>/dev/null || true

# -- Install --

install:
	install -d $(DESTDIR)/usr/bin
	install -d $(DESTDIR)/etc
	install -d $(DESTDIR)/etc/init.d
	for d in $(DAEMONS); do \
		[ -f $$d/$$d ] && install -m 0755 $$d/$$d $(DESTDIR)/usr/bin/ || true; \
	done
	for t in $(TOOLS); do \
		[ -f $$t/$$t ] && install -m 0755 $$t/$$t $(DESTDIR)/usr/bin/ || true; \
	done
	install -m 0644 config/raptor.conf $(DESTDIR)/etc/raptor.conf
	install -m 0755 config/S31raptor $(DESTDIR)/etc/init.d/S31raptor
# Sensor mode files, on the generations whose images ship none. A cv6xx
# OpenIPC image has no /etc/sensors at all -- hisilicon-opensdk builds the
# sensor libraries from source and carries no config directory -- so without
# these there is no lane map, Bayer order or sensor geometry on the board and
# the pipeline cannot be configured. Installed only for the platforms that
# need them, so a gen4 image keeps the vendor's own files untouched.
ifneq ($(strip $(HAL_SENSOR_DIR)),)
	install -d $(DESTDIR)/etc/sensors
	install -m 0644 config/sensors/$(HAL_SENSOR_DIR)/*.ini $(DESTDIR)/etc/sensors/
endif

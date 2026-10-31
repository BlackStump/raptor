#!/bin/sh
# Raptor full rebuild script
# Usage: ./build.sh <platform> <br_output> [target...]
# Examples:
#   ./build.sh t31 /path/to/buildroot/output
#   ./build.sh t20 /path/to/buildroot/output rvd rsd
#   ./build.sh t31 /path/to/buildroot/output clean
#   ./build.sh infinity6e /path/to/openipc-firmware/output rod
#   ./build.sh hi3516ev300 /path/to/openipc-firmware/output

set -e

platform="$1"
br_output="$2"
if [ $# -ge 2 ]; then
    shift 2
fi

# Folded to lower case once rather than spelling every arm twice: the
# SigmaStar list is twenty part numbers, and SSC337DE/ssc337DE/ssc337de are
# the same part however someone types it.
platform_lc=$(echo "$platform" | tr '[:upper:]' '[:lower:]')

case "$platform_lc" in
    t10) PLATFORM=T10 ;;
    t20) PLATFORM=T20 ;;
    t21) PLATFORM=T21 ;;
    t23) PLATFORM=T23 ;;
    t30) PLATFORM=T30 ;;
    t31) PLATFORM=T31 ;;
    t32) PLATFORM=T32 ;;
    t33) PLATFORM=T33 ;;
    t40) PLATFORM=T40 ;;
    t41) PLATFORM=T41 ;;
    a1)  PLATFORM=A1 ;;
    # Naming a family builds for the family and leaves the per-part caps
    # fields unmeasured; naming a part fills them in. The two are separate
    # arms because the part is not readable at runtime -- the chip ID is
    # family-wide, and ipctool reports SSC33X for ssc333/335/337 alike --
    # so this argument is the only place the part can come from.
    #
    # The part lists are the vendor's, and the spellings are the ones
    # OpenIPC's defconfigs already use for BR2_OPENIPC_SOC_MODEL, so a board
    # can pass its own value straight through. Variants that differ only in
    # package or DRAM still appear: they are separate parts to name, and
    # src/caps_sigmastar.inc is where they get grouped by encoder rate.
    infinity6b0) PLATFORM=INFINITY6B0 ;;
    ssc333|ssc333de|ssc335|ssc335de|ssc337|ssc337de)
        PLATFORM=INFINITY6B0; SOC_MODEL=$platform_lc ;;
    infinity6e) PLATFORM=INFINITY6E ;;
    ssc336d|ssc336q|ssc30kd|ssc30kq|ssc338d|ssc338q|ssc338g|ssc339g)
        PLATFORM=INFINITY6E; SOC_MODEL=$platform_lc ;;
    infinity6c) PLATFORM=INFINITY6C ;;
    ssc377|ssc377d|ssc377de|ssc377qe|ssc378de|ssc378qe)
        PLATFORM=INFINITY6C; SOC_MODEL=$platform_lc ;;
    # HiSilicon gen4. No family/part split here: the part IS the platform,
    # because unlike SigmaStar the chip ID is readable and part-specific
    # (0x12020EE0 reads 0x3516E300 on an EV300), so nothing has to be passed
    # in that the board cannot answer for itself.
    hi3516ev200) PLATFORM=HI3516EV200 ;;
    hi3516ev300) PLATFORM=HI3516EV300 ;;
    # HiSilicon gen5 (HiMPP V5), and here the family/part split IS needed,
    # unlike gen4 above: OpenIPC builds one hi3516cv6xx image for two dies and
    # its MPP answers "HI3516CV610_MPP_V1.0.2.0 B051" on both, so the platform
    # is the ABI and the die is a part to name. Whether the chip ID separates
    # them on a running board has not been checked; until it has, the die comes
    # from the build the way SigmaStar's does.
    #
    # The family spelling is OpenIPC's BR2_OPENIPC_SOC_FAMILY and the part
    # spellings are its BR2_OPENIPC_SOC_MODEL values, so a defconfig can pass
    # either straight through.
    hi3516cv6xx) PLATFORM=HI3516CV610 ;;
    hi3516cv608|hi3516cv610)
        PLATFORM=HI3516CV610; SOC_MODEL=$platform_lc ;;
    *)
        echo "Usage: $0 <platform> <br_output> [target...]"
        echo ""
        echo "Families: t10 t20 t21 t23 t30 t31 t32 t33 t40 t41 a1"
        echo "          infinity6b0 infinity6e infinity6c"
        echo "          hi3516ev200 hi3516ev300 hi3516cv6xx"
        echo ""
        echo "Parts. Naming one of these instead of its family fills in the"
        echo "per-part encoder ceilings, which a family build leaves unset:"
        echo "  infinity6b0  ssc333 ssc333de ssc335 ssc335de ssc337 ssc337de"
        echo "  infinity6e   ssc336d ssc336q ssc30kd ssc30kq"
        echo "               ssc338d ssc338q ssc338g ssc339g"
        echo "  infinity6c   ssc377 ssc377d ssc377de ssc377qe"
        echo "               ssc378de ssc378qe"
        echo "  hi3516cv6xx  hi3516cv608 hi3516cv610"
        echo ""
        echo "  <br_output> is the buildroot output directory containing"
        echo "  host/ with the cross-compiler and sysroot."
        exit 1
        ;;
esac

# Everything above is Ingenic and mipsel; the Infinity6 families are SigmaStar
# and ARM, and the Hi3516 parts are HiSilicon and ARM. That splits both the
# sysroot tuple and the compiler prefix, so neither can stay hardcoded below.
case "$PLATFORM" in
    HI3516EV200|HI3516EV300|HI3516CV610)
        # Soft-float, and note the tuples: musleabi, NOT musleabihf. These are
        # the ARM parts here that are not hard-float, so they get their own
        # arm rather than a label on Infinity6E's.
        #
        # Measured rather than assumed: Tag_ABI_VFP_args is absent from every
        # binary on a stock OpenIPC hi3516ev300 image -- libmpi, libisp,
        # libsecurec, the six lib_hi*.so algorithm libraries, all 34
        # libsns_*.so, and majestic itself -- while Tag_FP_arch reads VFPv4.
        # The FPU is used; the calling convention is not.
        #
        # Getting this wrong is not a link error. A hard-float daemon links,
        # loads and runs, and hands garbage to every float argument crossing
        # into MPI. raptor-hal's v4_common.h carries a #error on __ARM_PCS_VFP
        # so it cannot survive a compile either.
        #
        # Gen5 is the same answer measured again on its own libraries rather
        # than inherited: OpenIPC's hi3516cv6xx set (MPP V1.0.2.0 B051) carries
        # no Tag_ABI_VFP_args either, with Tag_FP_arch VFPv4. Same toolchain
        # tuple, same trap.
        SYSROOT_TUPLES="arm-openipc-linux-musleabi arm-buildroot-linux-musleabi \
                        arm-thingino-linux-musleabi"
        CROSS_CANDIDATES="arm-openipc-linux-musleabi- arm-buildroot-linux-musleabi- \
                          arm-linux-musleabi-"
        CROSS_GLOB="arm"
        ;;
    INFINITY6E)
        SYSROOT_TUPLES="arm-buildroot-linux-gnueabihf arm-openipc-linux-gnueabihf \
                        arm-thingino-linux-gnueabihf arm-buildroot-linux-musleabihf"
        # OpenIPC's Buildroot installs arm-openipc-*-gcc against an
        # arm-buildroot-* sysroot, so the prefix and the tuple are not the
        # same string and the prefix has to be looked for separately.
        CROSS_CANDIDATES="arm-openipc-linux-gnueabihf- arm-buildroot-linux-gnueabihf- \
                          arm-linux-gnueabihf-"
        CROSS_GLOB="arm"
        ;;
    INFINITY6B0)
        # musl, not glibc, and the distinction is fatal rather than cosmetic:
        # there is no glibc anywhere in an Infinity6B0 image, so a
        # gnueabihf-linked daemon does not reach its entry point. The families
        # split this way because the vendor blobs do -- Infinity6E's
        # libmi_sys.so declares NEEDED libc.so.6, while Infinity6B0's declare
        # no libc at all and resolve plain POSIX out of the loading process.
        #
        # Only standalone builds can get this wrong. Through Buildroot the
        # toolchain comes from the camera defconfig, which already knows.
        SYSROOT_TUPLES="arm-buildroot-linux-musleabihf arm-openipc-linux-musleabihf \
                        arm-thingino-linux-musleabihf"
        CROSS_CANDIDATES="arm-openipc-linux-musleabihf- arm-buildroot-linux-musleabihf- \
                          arm-linux-musleabihf-"
        CROSS_GLOB="arm"
        ;;
    INFINITY6C)
        # uClibc, glibc or musl, and unlike the other two families that is not
        # a contradiction. This family's vendor blobs declare a libc outright,
        # and the drop ships the whole MI set more than once -- one build
        # needing libc.so.0 and one needing libc.so.6 -- so the C library is a
        # property of the image rather than of the chip. All three are searched
        # because any of them can be the right answer; what matters is that the
        # toolchain matches the MI set the image carries, and mismatching it is
        # not a link error but a loader that never finds a libc the libraries
        # can use.
        #
        # Where Infinity6E is forced to glibc by its 4.9 kernel, this family
        # runs 5.10, so the smaller libcs are buildable against it at all.
        # musl is here because an OpenIPC base is one: its output carries
        # arm-buildroot-linux-musleabihf, and every board-verified Infinity6C
        # daemon so far was built with that toolchain.
        #
        # Only one of these exists in any given Buildroot output, so the search
        # order decides nothing.
        SYSROOT_TUPLES="arm-thingino-linux-uclibcgnueabihf arm-buildroot-linux-uclibcgnueabihf \
                        arm-openipc-linux-uclibcgnueabihf arm-thingino-linux-gnueabihf \
                        arm-buildroot-linux-gnueabihf arm-openipc-linux-gnueabihf \
                        arm-buildroot-linux-musleabihf arm-openipc-linux-musleabihf \
                        arm-thingino-linux-musleabihf"
        CROSS_CANDIDATES="arm-thingino-linux-uclibcgnueabihf- \
                          arm-buildroot-linux-uclibcgnueabihf- arm-linux-uclibcgnueabihf- \
                          arm-thingino-linux-gnueabihf- arm-buildroot-linux-gnueabihf- \
                          arm-linux-gnueabihf- arm-openipc-linux-musleabihf- \
                          arm-buildroot-linux-musleabihf- arm-linux-musleabihf-"
        CROSS_GLOB="arm"
        ;;
    *)
        SYSROOT_TUPLES="mipsel-openipc-linux-uclibc mipsel-buildroot-linux-uclibc \
                        mipsel-thingino-linux-uclibc mipsel-openipc-linux-musl \
                        mipsel-buildroot-linux-musl mipsel-thingino-linux-musl"
        CROSS_CANDIDATES="mipsel-linux- mipsel-openipc-linux-uclibc-"
        CROSS_GLOB="mipsel"
        ;;
esac

if [ -z "$br_output" ] || [ ! -d "$br_output" ]; then
    echo "Error: buildroot output directory required"
    echo "Usage: $0 <platform> <br_output> [target...]"
    exit 1
fi

TOOLCHAIN="$br_output/host/bin"

# Auto-detect sysroot tuple (uclibc or musl on Ingenic, gnueabihf on ARM)
SYSROOT=""
for tuple in $SYSROOT_TUPLES; do
    if [ -d "$br_output/host/$tuple/sysroot" ]; then
        SYSROOT="$br_output/host/$tuple/sysroot"
        break
    fi
done

if [ ! -d "$TOOLCHAIN" ]; then
    echo "Toolchain not found: $TOOLCHAIN"
    exit 1
fi

if [ -z "$SYSROOT" ]; then
    echo "Sysroot not found in $br_output/host/"
    # Unquoted on purpose: word-splitting collapses the line continuations
    # in the list above into single spaces.
    echo "  looked for:" $SYSROOT_TUPLES
    exit 1
fi

# Named candidates first so a working setup keeps the prefix it already used,
# then fall back to whatever <arch>*-gcc the toolchain actually installed.
CROSS_COMPILE=""
for c in $CROSS_CANDIDATES; do
    if [ -x "$TOOLCHAIN/${c}gcc" ]; then
        CROSS_COMPILE="$c"
        break
    fi
done
if [ -z "$CROSS_COMPILE" ]; then
    for gcc in "$TOOLCHAIN/$CROSS_GLOB"*-gcc; do
        [ -x "$gcc" ] || continue
        CROSS_COMPILE="$(basename "$gcc" gcc)"
        break
    done
fi

if [ -z "$CROSS_COMPILE" ]; then
    echo "No $CROSS_GLOB cross-compiler found in $TOOLCHAIN"
    echo "  looked for:" $CROSS_CANDIDATES
    exit 1
fi

export PATH="$TOOLCHAIN:$PATH"

MAKE_ARGS="PLATFORM=$PLATFORM CROSS_COMPILE=$CROSS_COMPILE SYSROOT=$SYSROOT"
[ -n "${SOC_MODEL:-}" ] && MAKE_ARGS="$MAKE_ARGS SOC_MODEL=$SOC_MODEL"

# AUDIO CODECS, ASKED FOR RATHER THAN ASSERTED
#
# AAC=1 OPUS=1 MP3=1 used to be unconditional, which is a claim about every
# sysroot this script can be pointed at. It is not true of an OpenIPC one:
# general/package has helix-aac and no helix-mp3 at all, so MP3=1 reached rac
# as
#
#   rac_play.c:18: fatal error: mp3dec.h: No such file or directory
#
# with every other daemon already built. Each switch is now asked of the
# sysroot the way TLS is below, so a codec the image does not ship costs that
# codec rather than the build.
#
# The headers are what is tested, not the libraries: they arrive together from
# one package, and the header is the name the source actually reaches for.
#
# AAC is two libraries under one switch -- faac to encode, helix-aac to decode
# -- and rsd's backchannel decodes, so both have to be present for the switch
# to be honest.
CODECS=""
if [ -f "$SYSROOT/usr/include/faac.h" ] && [ -f "$SYSROOT/usr/include/aacdec.h" ]; then
    MAKE_ARGS="$MAKE_ARGS AAC=1"
    CODECS="$CODECS aac"
fi
if [ -f "$SYSROOT/usr/include/opus/opus.h" ]; then
    MAKE_ARGS="$MAKE_ARGS OPUS=1"
    CODECS="$CODECS opus"
fi
if [ -f "$SYSROOT/usr/include/mp3dec.h" ]; then
    MAKE_ARGS="$MAKE_ARGS MP3=1"
    CODECS="$CODECS mp3"
fi

# TLS, AND WHICH MBEDTLS THAT MEANS
#
# rss_tls.c is written against the 3.x API -- mbedtls_pk_parse_keyfile takes
# an RNG there and does not in 2.x -- so "is there an mbedtls" is the wrong
# question to gate on. An OpenIPC sysroot answers yes twice: Majestic pins
# the end-of-life 2.25 at the shared usr/include and usr/lib, and
# mbedtls3-openipc installs 3.6 under its own usr/mbedtls3 prefix precisely
# so the two can coexist. This used to find the 2.25 and set TLS=1 against
# its headers, and the build stopped at
#
#   rss_tls.c:109: error: too many arguments to function mbedtls_pk_parse_keyfile
#
# with rvd already cleaned and never relinked. Nothing was wrong with the
# sysroot; the detection was asking about the wrong library.
#
# So look for a 3.x tree, private prefix first, and build HTTP-only when
# there is none rather than starting a build that cannot finish. This is the
# same choice general/package/raptor-streaming/raptor-streaming.mk makes for
# the firmware image, by hand, with MBEDTLS3_OPENIPC_CFLAGS and _LIBS.

# Answers with the major version, or with nothing, and SUCCEEDS EITHER WAY.
# The `|| true` is load-bearing: sed exits 2 on a header that is not there,
# 2.x has no build_info.h at all, and under `set -e` a failing command
# substitution in an assignment kills the script. It did -- every sysroot
# carrying only mbedtls 2.x, which is every one of them except the 6C's,
# exited 2 before printing a single line.
mbedtls_major() {
    sed -n 's/^#define MBEDTLS_VERSION_STRING  *"\([0-9][0-9]*\)\..*/\1/p' "$1" 2> /dev/null || true
}

TLS_CFLAGS=""
TLS_LDFLAGS=""
for prefix in "$SYSROOT/usr/mbedtls3" "$SYSROOT/usr" "$SYSROOT"; do
    [ -f "$prefix/lib/libmbedtls.so" ] || continue
    # 3.x moved the version defines out of version.h and into build_info.h,
    # which 2.x does not have at all, so both are read and the first answer
    # wins.
    major=$(mbedtls_major "$prefix/include/mbedtls/build_info.h")
    [ -n "$major" ] || major=$(mbedtls_major "$prefix/include/mbedtls/version.h")
    continue # local: build without TLS, compy has none
    TLS_CFLAGS="-I$prefix/include"
    # Whole library paths rather than -lmbedtls, because this is appended
    # after the Makefile's -L$SYSROOT/usr/lib and that directory holds
    # 2.25's libraries. Left to the linker's search order the link pairs
    # 3.x headers with 2.x code and says nothing about it -- the symptom is
    # libmbedtls.so.13 in DT_NEEDED, found only by looking.
    TLS_LDFLAGS="$prefix/lib/libmbedtls.so $prefix/lib/libmbedx509.so $prefix/lib/libmbedcrypto.so"
    MAKE_ARGS="$MAKE_ARGS TLS=1 WEBTORRENT=1"
    break
done

# COMPY, FROM THE SYSROOT WHEN IT IS THERE
#
# raptor's Makefile defaults LIB_COMPY_FILE to ../compy/build-$ARCH/libcompy.a,
# a CMake tree somebody built by hand at some point. That artefact outlives the
# toolchain that made it, and LTO turns the mismatch into a hard stop rather
# than a quiet one:
#
#   lto1: fatal error: bytecode stream in .../libcompy.a generated with LTO
#         version 16.0 instead of the expected 13.1
#
# -- an August build with thingino's gcc 16, linked by OpenIPC's gcc 13.3.
#
# A Buildroot output carrying the compy package already has a libcompy.a built
# by the very compiler found above, with the four header dependencies
# (slice99, datatype99, interface99, metalang99) installed beside it. Prefer
# it, and fall back to the sibling checkout when the sysroot has none, which is
# what a non-OpenIPC tree will do.
#
# COMPY_HAS_TLS has to be spelled out here even though the Makefile adds it
# under TLS=1: COMPY_CFLAGS becomes a command-line variable below and so beats
# the Makefile's +=, losing anything it would have appended. This is the same
# note raptor-streaming.mk carries for the same reason, and the same coupling
# -- it is only correct while the compy being linked was itself built with
# TLS, which the package's COMPY_TLS_MBEDTLS=ON makes true.
COMPY_LIB=""
COMPY_CFLAGS_VAL=""
if [ -f "$SYSROOT/usr/lib/libcompy.a" ] && [ -d "$SYSROOT/usr/include/compy" ]; then
    COMPY_LIB="$SYSROOT/usr/lib/libcompy.a"
    COMPY_CFLAGS_VAL="-I$SYSROOT/usr/include"
    [ -n "$TLS_CFLAGS" ] && COMPY_CFLAGS_VAL="$COMPY_CFLAGS_VAL -DCOMPY_HAS_TLS"
fi

echo "Building for $PLATFORM"
echo "  Output:  $br_output"
echo "  Sysroot: $SYSROOT"
echo "  Cross:   $CROSS_COMPILE"
if [ -n "$TLS_CFLAGS" ]; then
    echo "  TLS:     ${TLS_CFLAGS#-I}"
else
    echo "  TLS:     none -- no mbedtls 3.x in the sysroot, rhd builds HTTP-only"
fi
if [ -n "$COMPY_LIB" ]; then
    echo "  compy:   $COMPY_LIB"
else
    echo "  compy:   ../compy/build-<arch> (none in the sysroot)"
fi
echo "  Codecs: ${CODECS:- none}"

# A function rather than more words in MAKE_ARGS: these values carry paths and
# more than one of them per variable, and MAKE_ARGS is deliberately unquoted so
# the rest of it splits into separate arguments. They cannot share a slot.
#
# All of them are command-line assignments, which is what makes them stick --
# the Makefile spells LDFLAGS_TLS with := inside its TLS=1 arm and EXTRA_CFLAGS
# with ?=, and a command-line variable beats either.
#
# The TLS pair is passed unconditionally: with no 3.x in the sysroot both are
# empty, which is exactly what the Makefile would have used. The compy set is
# not, because an empty COMPY_CFLAGS would override the include paths the
# sibling-checkout fallback needs rather than leaving them alone.
run_make() {
    if [ -n "$COMPY_LIB" ]; then
        # shellcheck disable=SC2086
        make $MAKE_ARGS EXTRA_CFLAGS="$TLS_CFLAGS" LDFLAGS_TLS="$TLS_LDFLAGS" \
            COMPY_CFLAGS="$COMPY_CFLAGS_VAL" \
            LIB_COMPY_FILE="$COMPY_LIB" LIB_COMPY="$COMPY_LIB" "$@"
    else
        # shellcheck disable=SC2086
        make $MAKE_ARGS EXTRA_CFLAGS="$TLS_CFLAGS" LDFLAGS_TLS="$TLS_LDFLAGS" "$@"
    fi
}

# rwd only where there is a 3.x mbedtls to build it against. Unlike rhd, which
# degrades to HTTP-only and is worth having either way, rwd cannot be built at
# all without one: its link rule hardcodes -DRSS_HAS_TLS and
# -DMBEDTLS_ALLOW_PRIVATE_ACCESS, and rwd_dtls.c is 3.x source throughout --
# mbedtls_ssl_set_export_keys_cb, the MBEDTLS_PRIVATE accessors, the 5-argument
# mbedtls_pk_parse_keyfile. Against 2.25 headers it produces sixteen errors and
# takes the whole build down with it, which is what a gen4 build did.
#
# Asking for it unconditionally was survivable only while every sysroot in use
# carried 3.x. The HiSilicon ones do not. Note that the firmware image never
# built it either -- raptor-streaming.mk's DAEMONS list is rvd rsd rad rod ric
# rmq rhd rcd -- so this is a dev-build gap, not an image regression.
DEFAULT_TARGETS="rvd rsd rad rhd rod ric rmr rmd raptorctl ringdump rac"
if [ -n "$TLS_CFLAGS" ]; then
    DEFAULT_TARGETS="$DEFAULT_TARGETS rwd"
fi

if [ $# -eq 0 ]; then
    run_make distclean
    # shellcheck disable=SC2086
    run_make -j$(nproc) $DEFAULT_TARGETS
    run_make build
else
    run_make -j$(nproc) "$@"
fi

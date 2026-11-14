SRCS := rvd_main.c rvd_pipeline.c rvd_frame_loop.c rvd_ctrl.c rvd_osd.c rvd_ivs.c rvd_swmd.c rvd_ring_size.c
OBJS := $(SRCS:.c=.o)
BIN  := rvd

all: $(BIN)

# Relink when a linked-in library changes, not only when a source does: see
# LIB_HAL_VIDEO_FILE in the top-level Makefile. $(LIBS) mixes real files with
# -L/-l flags, and only the files can be a prerequisite. The build-info object
# is left out on purpose -- it is regenerated on every parse to stamp the time,
# and listing it would relink every daemon on every build.
#
# The top-level Makefile now names rvd's deps itself, and a value handed down
# on the sub-make command line beats this one; what is left here is the answer
# for a standalone `make -C rvd`, which has no parent to ask.
LIB_DEPS := $(filter %.a %.so,$(LIBS))

# Recompile when the platform selection changes, not only when a source does:
# see BUILD_CONFIG in the top-level Makefile. Empty for a standalone sub-make,
# which then behaves exactly as before.
CONFIG_STAMP ?=
$(OBJS): $(CONFIG_STAMP)

$(BIN): $(OBJS) $(LIB_DEPS)
	@echo "  LD      $@"
	$(Q)$(CC) -o $@ $(OBJS) $(LIBS) $(LDFLAGS)

%.o: %.c
	@echo "  CC      $<"
	$(Q)$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

clean:
	rm -f $(OBJS) $(OBJS:.o=.d) $(BIN)

-include $(OBJS:.o=.d)

.PHONY: all clean

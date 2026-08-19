/*
 * mayhem/lsan_off.c — the sanctioned build-time LeakSanitizer off-switch (SPEC §6.2 item 15).
 * Turns off only the end-of-process leak check; ASan stays fully active (heap/stack overflows,
 * use-after-free, etc. still abort). Compiled with the same $SANITIZER_FLAGS as the fuzz binaries
 * and linked into every ASan-built binary by mayhem/build.sh: the 11 fuzz_* targets and their -standalone reproducers.
 */
int __lsan_is_turned_off(void) { return 1; }

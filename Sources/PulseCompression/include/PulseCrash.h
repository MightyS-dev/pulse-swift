#ifndef PULSE_CRASH_H
#define PULSE_CRASH_H
#include <stddef.h>
#include <stdint.h>

// Crash recording. Everything that runs inside a signal handler uses only memory prepared beforehand and the calls
// open, write, close, clock_gettime, sigaction and raise. Nothing there allocates or takes a lock.

// Copies the crash file path into a static buffer and clears the "already written" mark. Returns 0 on success.
int pulse_crash_configure(const char *path);
// Starts recording the address ranges of loaded images (once per process; later images are added as they load).
void pulse_crash_load_images(void);
// Gives the calling thread an alternate signal stack, so a stack overflow on it can still be recorded.
// Does nothing when the thread already has one or the platform has none. Returns 1 when a stack is in place.
int pulse_crash_prepare_thread(void);
// Installs the handlers for SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE and SIGTRAP, remembering the previous actions.
// Returns the number of handlers installed (0 when already installed or unsupported).
int pulse_crash_install_signals(void);
// Restores the previous actions where our handler is still the current one.
void pulse_crash_uninstall_signals(void);
// While disabled the handlers write nothing and only pass the signal on.
void pulse_crash_set_enabled(int enabled);
int pulse_crash_is_enabled(void);
// Writes a complete record built elsewhere to the configured path and marks the crash as written, so the signal that
// usually follows (abort) does not replace it. Returns 0 on success.
int pulse_crash_write_record(const char *bytes, size_t count);
// Writes the record for one signal to an open descriptor: raw return addresses become image+0xoffset where the
// image is known, 0x<address> otherwise. Returns 0 on success.
int pulse_crash_write_signal_record(int fd, int signal_number, const uint64_t *frames, int count, int64_t millis);
// Formats one address the way a crash record does. Returns the length written, without the terminating zero.
size_t pulse_crash_format_frame(uint64_t address, char *output, size_t capacity);
// One shot guard for the exception path: returns 1 the first time, 0 afterwards. Lock free.
int pulse_crash_try_enter(void);
#endif

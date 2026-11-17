#include "PulseCrash.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/ucontext.h>
#define PULSE_CRASH_SIGNALS 1
#if !TARGET_OS_WATCH && !TARGET_OS_TV
#define PULSE_CRASH_ALTSTACK 1
#endif
#endif

#define PULSE_PATH_CAPACITY 1024
#define PULSE_IMAGE_CAPACITY 2048
#define PULSE_IMAGE_NAME 64
#define PULSE_FRAME_LIMIT 30
#define PULSE_SIGNAL_COUNT 6

static char crash_path[PULSE_PATH_CAPACITY];
static volatile sig_atomic_t crash_enabled = 0;
static volatile sig_atomic_t crash_written = 0;
static atomic_int signal_entered = 0;
static atomic_flag exception_entered = ATOMIC_FLAG_INIT;

static const int handled_signals[PULSE_SIGNAL_COUNT] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
static const char *const signal_names[PULSE_SIGNAL_COUNT] = { "SIGABRT", "SIGSEGV", "SIGBUS", "SIGILL", "SIGFPE", "SIGTRAP" };

struct pulse_image {
    _Atomic uint64_t start;
    _Atomic uint64_t end;
    char name[PULSE_IMAGE_NAME];
};
static struct pulse_image images[PULSE_IMAGE_CAPACITY];
static atomic_int image_reserved = 0;
static atomic_int images_registered = 0;

int pulse_crash_configure(const char *path) {
    if (!path) return -1;
    size_t length = strlen(path);
    if (length == 0 || length >= PULSE_PATH_CAPACITY) return -1;
    memcpy(crash_path, path, length + 1);
    crash_written = 0;
    atomic_store(&signal_entered, 0);
    atomic_flag_clear(&exception_entered);
    return 0;
}

void pulse_crash_set_enabled(int enabled) { crash_enabled = enabled ? 1 : 0; }
int pulse_crash_is_enabled(void) { return crash_enabled ? 1 : 0; }
int pulse_crash_try_enter(void) { return atomic_flag_test_and_set(&exception_entered) ? 0 : 1; }

// ---- Formatting helpers. Plain loops over caller memory, safe inside a signal handler.

struct pulse_buffer { char *data; size_t used; size_t capacity; };

static void put_text(struct pulse_buffer *buffer, const char *text) {
    while (*text && buffer->used + 1 < buffer->capacity) buffer->data[buffer->used++] = *text++;
    buffer->data[buffer->used] = 0;
}
static void put_hex(struct pulse_buffer *buffer, uint64_t value, int width) {
    char digits[17];
    int count = 0;
    do { digits[count++] = "0123456789abcdef"[value & 15]; value >>= 4; } while (value && count < 16);
    while (count < width && count < 16) digits[count++] = '0';
    put_text(buffer, "0x");
    while (count > 0 && buffer->used + 1 < buffer->capacity) buffer->data[buffer->used++] = digits[--count];
    buffer->data[buffer->used] = 0;
}
static void put_decimal(struct pulse_buffer *buffer, int64_t value) {
    char digits[21];
    int count = 0;
    uint64_t magnitude = value < 0 ? (uint64_t)(-(value + 1)) + 1 : (uint64_t)value;
    do { digits[count++] = (char)('0' + magnitude % 10); magnitude /= 10; } while (magnitude && count < 20);
    if (value < 0) put_text(buffer, "-");
    while (count > 0 && buffer->used + 1 < buffer->capacity) buffer->data[buffer->used++] = digits[--count];
    buffer->data[buffer->used] = 0;
}
static int write_all(int fd, const char *bytes, size_t count) {
    while (count > 0) {
        ssize_t written = write(fd, bytes, count);
        if (written < 0) { if (errno == EINTR) continue; return -1; }
        if (written == 0) return -1;
        bytes += written; count -= (size_t)written;
    }
    return 0;
}
static int64_t now_millis(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return 0;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

size_t pulse_crash_format_frame(uint64_t address, char *output, size_t capacity) {
    if (!output || capacity == 0) return 0;
    struct pulse_buffer buffer = { output, 0, capacity };
    output[0] = 0;
    int count = atomic_load(&image_reserved);
    if (count > PULSE_IMAGE_CAPACITY) count = PULSE_IMAGE_CAPACITY;
    for (int index = 0; index < count; index++) {
        uint64_t end = atomic_load(&images[index].end);
        uint64_t start = atomic_load(&images[index].start);
        if (end > start && address >= start && address < end) {
            put_text(&buffer, images[index].name);
            put_text(&buffer, "+");
            put_hex(&buffer, address - start, 0);
            return buffer.used;
        }
    }
    put_hex(&buffer, address, 16);
    return buffer.used;
}

int pulse_crash_write_signal_record(int fd, int signal_number, const uint64_t *frames, int count, int64_t millis) {
    if (fd < 0) return -1;
    char storage[4096];
    struct pulse_buffer buffer = { storage, 0, sizeof(storage) };
    storage[0] = 0;
    const char *name = "SIGNAL";
    for (int index = 0; index < PULSE_SIGNAL_COUNT; index++) {
        if (handled_signals[index] == signal_number) name = signal_names[index];
    }
    put_text(&buffer, "MPC1\nkind crash\ntype ");
    put_text(&buffer, name);
    put_text(&buffer, "\ntime ");
    put_decimal(&buffer, millis);
    put_text(&buffer, "\nsymbolicated 0\n");
    if (count > PULSE_FRAME_LIMIT) count = PULSE_FRAME_LIMIT;
    for (int index = 0; frames && index < count; index++) {
        char line[PULSE_IMAGE_NAME + 40];
        pulse_crash_format_frame(frames[index], line, sizeof(line));
        // Leave room for the closing line so a full record still validates.
        if (buffer.used + strlen(line) + 16 >= buffer.capacity) break;
        put_text(&buffer, "frame ");
        put_text(&buffer, line);
        put_text(&buffer, "\n");
    }
    put_text(&buffer, "end\n");
    return write_all(fd, storage, buffer.used);
}

// Opens the crash file for writing. A missing directory is created here, at crash time, so nothing touches the disk
// before it is needed (mkdir and open are async-signal-safe; the path copy lives on the stack).
static int open_crash_file(void) {
    int fd = open(crash_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd >= 0 || errno != ENOENT) return fd;
    char partial[PULSE_PATH_CAPACITY];
    size_t length = strlen(crash_path);
    if (length == 0 || length >= PULSE_PATH_CAPACITY) return -1;
    memcpy(partial, crash_path, length + 1);
    for (size_t at = 1; at < length; at++) {
        if (partial[at] != '/') continue;
        partial[at] = 0;
        mkdir(partial, 0700);
        partial[at] = '/';
    }
    return open(crash_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
}

int pulse_crash_write_record(const char *bytes, size_t count) {
    if (!bytes || crash_path[0] == 0) return -1;
    int fd = open_crash_file();
    if (fd < 0) return -1;
    int result = write_all(fd, bytes, count);
    close(fd);
    if (result == 0) crash_written = 1;
    return result;
}

#if defined(PULSE_CRASH_SIGNALS)

static struct sigaction previous_actions[PULSE_SIGNAL_COUNT];
static atomic_int signals_installed = 0;

static uint64_t strip_pointer(uint64_t value) {
#if defined(__arm64__) || defined(__aarch64__)
    // Return addresses of arm64e code carry an authentication code in the high bits.
    return value & 0x0000000FFFFFFFFFULL;
#else
    return value;
#endif
}

// Walks the frame records of the interrupted thread, bounded by that thread's stack, reading only memory.
static int collect_frames(void *context, uint64_t *frames, int capacity) {
    ucontext_t *user = (ucontext_t *)context;
    if (!user || !user->uc_mcontext || capacity <= 0) return 0;
    uint64_t pc = 0, fp = 0;
#if defined(__arm64__) || defined(__aarch64__)
    pc = (uint64_t)__darwin_arm_thread_state64_get_pc(user->uc_mcontext->__ss);
    fp = (uint64_t)__darwin_arm_thread_state64_get_fp(user->uc_mcontext->__ss);
#elif defined(__x86_64__)
    pc = user->uc_mcontext->__ss.__rip;
    fp = user->uc_mcontext->__ss.__rbp;
#else
    return 0;
#endif
    int count = 0;
    if (pc) frames[count++] = strip_pointer(pc);
    pthread_t thread = pthread_self();
    uint64_t top = (uint64_t)(uintptr_t)pthread_get_stackaddr_np(thread);
    uint64_t size = (uint64_t)pthread_get_stacksize_np(thread);
    uint64_t bottom = top > size ? top - size : 0;
    while (count < capacity && fp >= bottom && fp + 16 <= top && (fp & 7) == 0) {
        const uint64_t *record = (const uint64_t *)(uintptr_t)fp;
        uint64_t next = record[0], address = strip_pointer(record[1]);
        if (address == 0) break;
        frames[count++] = address;
        if (next <= fp) break;
        fp = next;
    }
    return count;
}

static void pulse_signal_handler(int signal_number, siginfo_t *info, void *context);

// The signal being handled always goes back to its previous action, so it can never loop back here. The other
// signals are restored only where our handler is still the current one, so a handler installed later stays.
static void restore_previous(int signal_number) {
    for (int index = 0; index < PULSE_SIGNAL_COUNT; index++) {
        struct sigaction current;
        int ours = sigaction(handled_signals[index], NULL, &current) == 0 && (current.sa_flags & SA_SIGINFO)
            && current.sa_sigaction == pulse_signal_handler;
        if (ours || handled_signals[index] == signal_number) {
            sigaction(handled_signals[index], &previous_actions[index], NULL);
        }
    }
    atomic_store(&signals_installed, 0);
}

static void pulse_signal_handler(int signal_number, siginfo_t *info, void *context) {
    (void)info;
    int saved = errno;
    int first = 0;
    int expected = 0;
    if (atomic_compare_exchange_strong(&signal_entered, &expected, 1)) first = 1;
    if (first && crash_enabled && !crash_written && crash_path[0]) {
        uint64_t frames[PULSE_FRAME_LIMIT];
        int count = collect_frames(context, frames, PULSE_FRAME_LIMIT);
        int fd = open_crash_file();
        if (fd >= 0) {
            if (pulse_crash_write_signal_record(fd, signal_number, frames, count, now_millis()) == 0) crash_written = 1;
            close(fd);
        }
    }
    // Hand the signal to whatever was there before: the system crash reporter or another handler.
    restore_previous(signal_number);
    errno = saved;
    raise(signal_number);
}

static void image_added(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (!header) return;
#if defined(__LP64__)
    const struct mach_header_64 *image = (const struct mach_header_64 *)header;
    const uint8_t *command = (const uint8_t *)(image + 1);
    const uint32_t segment = LC_SEGMENT_64;
#else
    const struct mach_header *image = header;
    const uint8_t *command = (const uint8_t *)(image + 1);
    const uint32_t segment = LC_SEGMENT;
#endif
    uint64_t size = 0;
    for (uint32_t index = 0; index < image->ncmds; index++) {
        const struct load_command *load = (const struct load_command *)command;
        if (load->cmd == segment) {
#if defined(__LP64__)
            const struct segment_command_64 *found = (const struct segment_command_64 *)command;
#else
            const struct segment_command *found = (const struct segment_command *)command;
#endif
            if (strncmp(found->segname, "__TEXT", 16) == 0) { size = (uint64_t)found->vmsize; break; }
        }
        if (load->cmdsize == 0) break;
        command += load->cmdsize;
    }
    if (size == 0) return;
    int index = atomic_fetch_add(&image_reserved, 1);
    if (index >= PULSE_IMAGE_CAPACITY) return;
    Dl_info info;
    const char *name = "image";
    if (dladdr(header, &info) && info.dli_fname) {
        const char *slash = strrchr(info.dli_fname, '/');
        name = slash ? slash + 1 : info.dli_fname;
    }
    size_t length = strlen(name);
    if (length >= PULSE_IMAGE_NAME) length = PULSE_IMAGE_NAME - 1;
    for (size_t at = 0; at < length; at++) {
        char c = name[at];
        images[index].name[at] = (c == '\n' || c == '\r' || c == ' ') ? '_' : c;
    }
    images[index].name[length] = 0;
    uint64_t start = (uint64_t)(uintptr_t)header;
    atomic_store(&images[index].start, start);
    atomic_store(&images[index].end, start + size);
}

void pulse_crash_load_images(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&images_registered, &expected, 1)) return;
    _dyld_register_func_for_add_image(image_added);
}

int pulse_crash_prepare_thread(void) {
#if defined(PULSE_CRASH_ALTSTACK)
    stack_t current;
    if (sigaltstack(NULL, &current) != 0) return 0;
    if (!(current.ss_flags & SS_DISABLE) && current.ss_size > 0) return 1;
    size_t size = 65536;
    if (size < (size_t)SIGSTKSZ) size = (size_t)SIGSTKSZ;
    void *memory = malloc(size);
    if (!memory) return 0;
    stack_t stack;
    memset(&stack, 0, sizeof(stack));
    stack.ss_sp = memory;
    stack.ss_size = size;
    stack.ss_flags = 0;
    if (sigaltstack(&stack, NULL) != 0) { free(memory); return 0; }
    return 1;
#else
    return 0;
#endif
}

int pulse_crash_install_signals(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&signals_installed, &expected, 1)) return 0;
    int installed = 0;
    for (int index = 0; index < PULSE_SIGNAL_COUNT; index++) {
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_sigaction = pulse_signal_handler;
        action.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&action.sa_mask);
        if (sigaction(handled_signals[index], &action, &previous_actions[index]) == 0) installed++;
    }
    return installed;
}

void pulse_crash_uninstall_signals(void) {
    for (int index = 0; index < PULSE_SIGNAL_COUNT; index++) {
        struct sigaction current;
        if (sigaction(handled_signals[index], NULL, &current) != 0) continue;
        if ((current.sa_flags & SA_SIGINFO) && current.sa_sigaction == pulse_signal_handler) {
            sigaction(handled_signals[index], &previous_actions[index], NULL);
        }
    }
    atomic_store(&signals_installed, 0);
}

#else

void pulse_crash_load_images(void) {}
int pulse_crash_prepare_thread(void) { return 0; }
int pulse_crash_install_signals(void) { return 0; }
void pulse_crash_uninstall_signals(void) {}

#endif

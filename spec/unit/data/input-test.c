/* Linux emulator fixture: run the actual evdev poller against owned pipes.
 * Hardware fake-event generators are deliberately unavailable in this module.
 */
#define _GNU_SOURCE
#include <stdlib.h>
#include <sys/ioctl.h>

static void generateFakeEvent(int pipefd[2] __attribute__((unused)))
{
    abort();
}

#define luaopen_input luaopen_input_test
#include "../../../input/input.c"

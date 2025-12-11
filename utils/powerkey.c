//
// Shutdown the system upon short press on power on/off button
//

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <linux/input.h>
#include <fcntl.h>

#define DEV_PATH "/dev/input/event0"

int main() {
    int fd;
    struct input_event ev;

    fd = open(DEV_PATH, O_RDONLY);
    if (fd < 0) {
        perror("Could not open event device");
        return 1;
    }

    // Loop forever waiting for the event
    while (1) {
        // read() blocks until an event is available
        ssize_t n = read(fd, &ev, sizeof(struct input_event));
        
        // If read() was interrupted, just try again
        if (n == -1) {
            continue;
        }

        if (ev.type == EV_KEY && ev.code == KEY_POWER && ev.value == 1) {
            system("/sbin/poweroff");
        }
    }
    
    return 0;
}

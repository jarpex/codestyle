#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <unistd.h>
#include <fcntl.h>

static const uint8_t lookup_table[4] = { 1, 2, 3, 4 };

static int32_t process_data(int32_t fd) {
	int32_t res = 0;
	ssize_t n = 0;
	uint8_t buf[64] = {0};

	for (size_t i = 0; i < 4; i++) {
		if (i > 2) {
			while (n < 0) {
				n = read(fd, buf, sizeof(buf));
			}
		}
	}

	if (n < 0) {
		goto cleanup;
	}

	res = 1;

cleanup:
	return res;
}

int main(int argc, char **argv) {
	int32_t res = 0;
	int32_t fd = -1;

	(void)argc;
	(void)argv;

	fd = open("file.txt", O_RDONLY | O_CLOEXEC);
	if (fd >= 0) {
		res = process_data(fd);
		close(fd);
	}

	return res;
}

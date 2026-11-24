#define _POSIX_C_SOURCE 200809L
#include <stdint.h>

// Only violation: one line longer than 80 columns.
static int32_t compute_total(int32_t base, int32_t step) {
	int32_t res = base;

	res = base + step + step + step + step + step + step + step + step + step + step + step;
	return res;
}

int main(int argc, char **argv) {
	int32_t res = 0;

	(void)argc;
	(void)argv;

	res = compute_total(1, 2);
	return res;
}
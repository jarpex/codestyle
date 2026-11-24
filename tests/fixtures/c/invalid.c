#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <assert.h>

// Violations:
// c/internal-linkage: non-static function
// c/no-camel-case: badCaseName
// c/explicit-int-types: short
// c/no-vla: int arr[n]
void badCaseName(int n) {
	short bad_type = 1;
	int arr[n];
	(void)bad_type;
	(void)arr;
}

static int32_t trigger_checks(int32_t a, int32_t b) {
	// c/uninitialized-local
	int32_t uninit;
	// c/declarations-at-top: code before decl below
	uninit = 10;
	int32_t decl_late = 5;

	// c/bitwise-pow2: * 4
	decl_late = decl_late * 4;

	// security/assert-no-side-effects: a++
	assert(a++ > 0);

	// security/no-post-overflow-check
	if (a + b < a) {
		uninit = 0;
	}

	// c/infinite-loop-for: while (1)
	while (1) {
		break;
	}

	// style/mandatory-braces: missing braces
	if (a > 0)
		uninit = 1;

	// security/banned-functions: strcpy
	char buf[32] = {0};
	strcpy(buf, "bad");

	// security/cloexec-required: open without O_CLOEXEC
	int32_t fd = open("/dev/null", O_RDONLY);
	// security/eintr-loop: read outside loop
	read(fd, buf, 1);
	close(fd);

	// c/no-subroutine-abort: exit() in non-main
	if (a < 0) {
		exit(1);
	}

	// c/return-var-name: labeled_statement exists, but return != res
cleanup:
	return uninit;
}

int main(int argc, char **argv) {
	(void)argc;
	(void)argv;
	return 0;
}

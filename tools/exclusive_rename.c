#define _DARWIN_C_SOURCE 1

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

static bool is_safe_relative_path(const char *value, bool allow_slashes) {
    if (value == NULL || value[0] == '\0' || value[0] == '/') {
        return false;
    }
    if (!allow_slashes && strchr(value, '/') != NULL) {
        return false;
    }

    const char *component = value;
    for (const char *cursor = value;; cursor++) {
        if (*cursor != '/' && *cursor != '\0') {
            continue;
        }
        const size_t length = (size_t)(cursor - component);
        if (length == 0 || (length == 1 && component[0] == '.') ||
            (length == 2 && component[0] == '.' && component[1] == '.')) {
            return false;
        }
        if (*cursor == '\0') {
            return true;
        }
        component = cursor + 1;
    }
}

int main(int argc, char *argv[]) {
    if (argc != 4) {
        fprintf(stderr, "usage: exclusive_rename PARENT SOURCE_RELATIVE DESTINATION_NAME\n");
        return 64;
    }
    if (argv[1][0] != '/' || !is_safe_relative_path(argv[2], true) ||
        !is_safe_relative_path(argv[3], false)) {
        fprintf(stderr, "exclusive rename received an unsafe path\n");
        return 64;
    }

    const int parent_fd = open(argv[1], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (parent_fd == -1) {
        fprintf(stderr, "cannot open exclusive rename parent %s: %s\n", argv[1], strerror(errno));
        return 74;
    }

    struct stat source_stat;
    if (fstatat(parent_fd, argv[2], &source_stat, AT_SYMLINK_NOFOLLOW) == -1) {
        const int error = errno;
        close(parent_fd);
        fprintf(stderr, "cannot inspect exclusive rename source %s: %s\n", argv[2],
                strerror(error));
        return 74;
    }
    if (!S_ISDIR(source_stat.st_mode)) {
        close(parent_fd);
        fprintf(stderr, "exclusive rename source is not a directory: %s\n", argv[2]);
        return 65;
    }

    if (renameatx_np(parent_fd, argv[2], parent_fd, argv[3], RENAME_EXCL) == -1) {
        const int error = errno;
        close(parent_fd);
        fprintf(stderr, "exclusive rename failed for %s: %s\n", argv[3], strerror(error));
        return error == EEXIST ? 73 : 74;
    }

    if (close(parent_fd) == -1) {
        // The rename is already visible and must never be rolled back. Report success so callers
        // proceed to verification of the exact published directory instead of treating close(2)
        // as a pre-visibility failure.
        return 0;
    }
    return 0;
}

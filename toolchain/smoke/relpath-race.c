// Two threads making relative-path syscalls at once must not corrupt each
// other's paths (patches/wasix-libc). Thread 1 creates ./d1/file_NNNN.ibt
// with O_CREAT|O_EXCL while thread 2 probes names under ./d2. Afterwards
// every file is looked up through a directory descriptor (openat), which
// bypasses libc's cwd-relative path resolution, and both directories are
// listed for strays. Exits 0 when every file exists under its own name and
// nothing else does; with the unpatched libc, some creates land on a
// spliced name and their files are missing.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define N 3000

static volatile int stop = 0;
static volatile long noise_calls = 0;

static void *noise(void *arg) {
    (void)arg;
    while (!stop) {
        access("./d2/a_rather_long_file_name_that_does_not_exist_here", F_OK);
        access("./d2/x", F_OK);
        noise_calls += 2;
    }
    return NULL;
}

static int list_dir(int fd, const char *label, int expect_files) {
    int strays = 0;
    int dfd = dup(fd);
    DIR *d = fdopendir(dfd);
    if (!d) {
        perror("fdopendir");
        return 1;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
            continue;
        unsigned n;
        char suffix[16];
        if (expect_files && sscanf(e->d_name, "file_%u.ibt%15s", &n, suffix) == 1 &&
            n < N && strlen(e->d_name) == strlen("file_0000.ibt"))
            continue;
        strays++;
        if (strays <= 20)
            printf("stray in %s: \"%s\" (len %zu)\n", label, e->d_name, strlen(e->d_name));
    }
    closedir(d);
    return strays;
}

int main(void) {
    if (mkdir("d1", 0777) != 0 || mkdir("d2", 0777) != 0) {
        perror("mkdir");
        return 2;
    }
    int d1_fd = open("./d1", O_RDONLY | O_DIRECTORY);
    int d2_fd = open("./d2", O_RDONLY | O_DIRECTORY);
    if (d1_fd < 0 || d2_fd < 0) {
        perror("open dir");
        return 2;
    }

    pthread_t t;
    if (pthread_create(&t, NULL, noise, NULL) != 0) {
        perror("pthread_create");
        return 2;
    }

    int create_errors = 0;
    char name[64];
    for (int i = 0; i < N; i++) {
        snprintf(name, sizeof name, "./d1/file_%04d.ibt", i);
        int fd = open(name, O_RDWR | O_CREAT | O_EXCL, 0644);
        if (fd < 0) {
            create_errors++;
            if (create_errors <= 20)
                printf("create %s: errno %d (%s)\n", name, errno, strerror(errno));
        } else {
            close(fd);
        }
    }
    stop = 1;
    pthread_join(t, NULL);

    int missing = 0;
    for (int i = 0; i < N; i++) {
        snprintf(name, sizeof name, "file_%04d.ibt", i);
        int fd = openat(d1_fd, name, O_RDONLY);
        if (fd < 0) {
            missing++;
            if (missing <= 20)
                printf("missing in d1: %s (errno %d)\n", name, errno);
        } else {
            close(fd);
        }
    }
    int strays = list_dir(d1_fd, "d1", 1) + list_dir(d2_fd, "d2", 0);
    printf("noise calls %ld, create errors %d, missing %d, strays %d\n",
           noise_calls, create_errors, missing, strays);
    return (create_errors || missing || strays) ? 1 : 0;
}

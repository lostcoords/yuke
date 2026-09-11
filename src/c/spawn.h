#if defined(__APPLE__)
// Apple's spawn.h pulls Mach message headers that translate-c cannot size, so the prototypes live here.
// The types and values come from sys/_types.h, sys/spawn.h, sys/fcntl.h, and signal.h of the Zig-bundled headers.
typedef int pid_t;
typedef unsigned short mode_t;
typedef unsigned int sigset_t;
typedef void *posix_spawnattr_t;
typedef void *posix_spawn_file_actions_t;
#define POSIX_SPAWN_SETSIGMASK 0x0008
#define POSIX_SPAWN_SETSID 0x0400
#define O_RDONLY 0x0000
int sigemptyset(sigset_t *);
int posix_spawnattr_init(posix_spawnattr_t *);
int posix_spawnattr_destroy(posix_spawnattr_t *);
int posix_spawnattr_setflags(posix_spawnattr_t *, short);
int posix_spawnattr_setsigmask(posix_spawnattr_t *, const sigset_t *);
int posix_spawn_file_actions_init(posix_spawn_file_actions_t *);
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *);
int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *, int, const char *, int, mode_t);
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *, int, int);
int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *, const char *);
int posix_spawn(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const[], char *const[]);
pid_t getsid(pid_t);
pid_t getpgid(pid_t);
#else
// The feature macro exposes POSIX_SPAWN_SETSID on glibc and posix_spawn_file_actions_addchdir_np on musl.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <spawn.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#endif

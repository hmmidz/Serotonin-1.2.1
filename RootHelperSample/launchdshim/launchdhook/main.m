#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <stdio.h>
#include "fishhook.h"
#include <spawn.h>

int
posix_spawnattr_set_launch_type_np(posix_spawnattr_t *attr, uint8_t launch_type);

int (*orig_csops)(pid_t pid, unsigned int  ops, void * useraddr, size_t usersize);
int (*orig_csops_audittoken)(pid_t pid, unsigned int  ops, void * useraddr, size_t usersize, audit_token_t * token);
int (*orig_posix_spawn)(pid_t * __restrict pid, const char * __restrict path,
                        const posix_spawn_file_actions_t *file_actions,
                        const posix_spawnattr_t * __restrict attrp,
                        char *const argv[ __restrict], char *const envp[ __restrict]);
int (*orig_posix_spawnp)(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict file_actions, const posix_spawnattr_t *restrict attrp, char *const argv[restrict], char *const envp[restrict]);

bool (*orig_os_variant_has_internal_content)(const char * __unused subsystem);

int hooked_csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize) {
    int result = orig_csops(pid, ops, useraddr, usersize);
    if (ops == 0) { // CS_OPS_STATUS
        *((uint32_t *)useraddr) |= 0x4000000; // CS_PLATFORM_BINARY
    }
    return result;
}

int hooked_csops_audittoken(pid_t pid, unsigned int ops, void * useraddr, size_t usersize, audit_token_t * token) {
    int result = orig_csops_audittoken(pid, ops, useraddr, usersize, token);
    if (ops == 0) { // CS_OPS_STATUS
        *((uint32_t *)useraddr) |= 0x4000000; // CS_PLATFORM_BINARY
    }
    return result;
}

void change_launchtype(const posix_spawnattr_t *attrp, const char *restrict path) {
    const char *prefixes[] = {
        "/private/var",
        "/var",
        "/private/preboot"
    };

    for (size_t i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); ++i) {
        size_t prefix_len = strlen(prefixes[i]);
        if (strncmp(path, prefixes[i], prefix_len) == 0) {
            FILE *file = fopen("/var/mobile/lunchd.log", "a");
            if (file && attrp != 0) {
                char output[1024];
                sprintf(output, "[lunchd] setting launch type path %s to 0\n", path);
                fputs(output, file);
                fclose(file);
            }
            posix_spawnattr_set_launch_type_np((posix_spawnattr_t *)attrp, 0); // needs ios 16.0 sdk
            break;
        }
    }
}

void hook_springboard(const char *restrict path) {
    const char *springboardPath = "/System/Library/CoreServices/SpringBoard.app/SpringBoard";
    const char *coolerSpringboard = "/var/jb/SpringBoard";
        if (strncmp(path, springboardPath, strlen(springboardPath)) == 0) {
            FILE *file = fopen("/var/mobile/lunchd.log", "a");
            char output[1024];
            sprintf(output, "[lunchd] changing path %s to %s\n", path, coolerSpringboard);
            fputs(output, file);
            fclose(file);
            path = coolerSpringboard;
        }
    }

int hooked_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *file_actions, const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]) {
    hook_springboard(path);
    int result = orig_posix_spawn(pid, path, file_actions, attrp, argv, envp);
    change_launchtype(attrp, path);
    return result;
}

int hooked_posix_spawnp(pid_t *restrict pid, const char *restrict path, const posix_spawn_file_actions_t *restrict file_actions, posix_spawnattr_t *attrp, char *const argv[restrict], char *const envp[restrict]) {
    change_launchtype(attrp, path);
    hook_springboard(path);
    return orig_posix_spawnp(pid, path, file_actions, attrp, argv, envp);
}

bool hooked_os_variant_has_internal_content(const char * __unused subsystem) {
    return true;
}

__attribute__((constructor)) static void init(int argc, char **argv) {
    FILE *file;
    file = fopen("/var/mobile/lunchd.log", "w");
    char output[1024];
    sprintf(output, "[lunchd] launchdhook pid %d", getpid());
    printf("[lunchd] launchdhook pid %d", getpid());
    fputs(output, file);
    fclose(file);
    sync();
    
    struct rebinding rebindings[] = (struct rebinding[]){
        {"csops", hooked_csops, (void *)&orig_csops},
        {"csops_audittoken", hooked_csops_audittoken, (void *)&orig_csops_audittoken},
        {"posix_spawn", hooked_posix_spawn, (void *)&orig_posix_spawn},
        {"posix_spawnp", hooked_posix_spawnp, (void *)&orig_posix_spawnp},
        {"os_variant_has_internal_content", hooked_os_variant_has_internal_content, (void *)&orig_os_variant_has_internal_content}
    };
    rebind_symbols(rebindings, sizeof(rebindings)/sizeof(struct rebinding));
}
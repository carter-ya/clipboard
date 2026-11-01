#include "desktop_shell.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int valid_identity(const char *value) {
  if (!value || strlen(value) != 64)
    return 0;
  for (unsigned i = 0; i < 64; ++i)
    if (!((value[i] >= '0' && value[i] <= '9') ||
          (value[i] >= 'a' && value[i] <= 'f')))
      return 0;
  return 1;
}
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
struct clipboard_instance {
  HANDLE mutex, activate, stop, thread, mapping;
  DWORD *process_id;
  clipboard_shell_callback callback;
  void *context;
};
static DWORD WINAPI instance_loop(void *value) {
  clipboard_instance *instance = value;
  HANDLE handles[] = {instance->stop, instance->activate};
  while (WaitForMultipleObjects(2, handles, FALSE, INFINITE) ==
         WAIT_OBJECT_0 + 1)
    if (instance->callback)
      instance->callback(instance->context, 2, NULL);
  return 0;
}
void clipboard_instance_destroy(clipboard_instance *instance) {
  if (!instance)
    return;
  if (instance->thread) {
    SetEvent(instance->stop);
    WaitForSingleObject(instance->thread, INFINITE);
    CloseHandle(instance->thread);
  }
  if (instance->process_id)
    UnmapViewOfFile(instance->process_id);
  if (instance->mapping)
    CloseHandle(instance->mapping);
  if (instance->stop)
    CloseHandle(instance->stop);
  if (instance->activate)
    CloseHandle(instance->activate);
  if (instance->mutex)
    CloseHandle(instance->mutex);
  free(instance);
}
clipboard_instance *clipboard_instance_create(const char *identity,
                                              clipboard_shell_callback callback,
                                              void *context, int *status) {
  if (status)
    *status = -1;
  if (!valid_identity(identity))
    return NULL;
  WCHAR key[128], event_name[128], mapping_name[128];
  char ascii[128];
  snprintf(ascii, sizeof(ascii), "Local\\ClipboardDesktop.%s.lock", identity);
  MultiByteToWideChar(CP_UTF8, 0, ascii, -1, key, 128);
  snprintf(ascii, sizeof(ascii), "Local\\ClipboardDesktop.%s.activate",
           identity);
  MultiByteToWideChar(CP_UTF8, 0, ascii, -1, event_name, 128);
  snprintf(ascii, sizeof(ascii), "Local\\ClipboardDesktop.%s.pid", identity);
  MultiByteToWideChar(CP_UTF8, 0, ascii, -1, mapping_name, 128);
  clipboard_instance *instance = calloc(1, sizeof(*instance));
  if (!instance)
    return NULL;
  instance->mutex = CreateMutexW(NULL, FALSE, key);
  DWORD mutex_error = GetLastError();
  if (!instance->mutex) {
    clipboard_instance_destroy(instance);
    return NULL;
  }
  instance->activate = CreateEventW(NULL, FALSE, FALSE, event_name);
  if (!instance->activate) {
    clipboard_instance_destroy(instance);
    return NULL;
  }
  if (mutex_error == ERROR_ALREADY_EXISTS) {
    /* A short startup rendezvous lets the launching process grant foreground
       activation to the existing UI before signaling its private event. */
    for (unsigned attempt = 0; attempt < 100; ++attempt) {
      HANDLE mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, mapping_name);
      if (mapping) {
        const DWORD *pid =
            MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, sizeof(DWORD));
        if (pid && *pid)
          AllowSetForegroundWindow(*pid);
        if (pid)
          UnmapViewOfFile(pid);
        CloseHandle(mapping);
        break;
      }
      Sleep(10);
    }
    int signaled = SetEvent(instance->activate) != 0;
    clipboard_instance_destroy(instance);
    if (status)
      *status = signaled ? 0 : -1;
    return NULL;
  }
  instance->mapping =
      CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0,
                         sizeof(DWORD), mapping_name);
  if (!instance->mapping) {
    clipboard_instance_destroy(instance);
    return NULL;
  }
  instance->process_id =
      MapViewOfFile(instance->mapping, FILE_MAP_WRITE, 0, 0, sizeof(DWORD));
  if (!instance->process_id) {
    clipboard_instance_destroy(instance);
    return NULL;
  }
  *instance->process_id = GetCurrentProcessId();
  MemoryBarrier();
  instance->callback = callback;
  instance->context = context;
  instance->stop = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!instance->stop) {
    clipboard_instance_destroy(instance);
    return NULL;
  }
  instance->thread = CreateThread(NULL, 0, instance_loop, instance, 0, NULL);
  if (!instance->thread) {
    clipboard_instance_destroy(instance);
    return NULL;
  }
  if (status)
    *status = 1;
  return instance;
}
#elif defined(__linux__)
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
struct clipboard_instance {
  int lock, server, wake[2], has_thread;
  pthread_t thread;
  char socket_path[108];
  clipboard_shell_callback callback;
  void *context;
};
static int private_directory(const char *path) {
  if (mkdir(path, 0700) != 0 && errno != EEXIST)
    return 0;
  struct stat metadata;
  return lstat(path, &metadata) == 0 && S_ISDIR(metadata.st_mode) &&
         metadata.st_uid == geteuid() && (metadata.st_mode & 077) == 0;
}
static void *instance_loop(void *value) {
  clipboard_instance *instance = value;
  struct pollfd descriptors[] = {{instance->wake[0], POLLIN, 0},
                                 {instance->server, POLLIN, 0}};
  for (;;) {
    int result = poll(descriptors, 2, -1);
    if (result < 0) {
      if (errno == EINTR)
        continue;
      break;
    }
    if (descriptors[0].revents)
      break;
    if (descriptors[1].revents & POLLIN) {
      int client = accept(instance->server, NULL, NULL);
      if (client < 0)
        continue;
      struct pollfd ready = {client, POLLIN, 0};
      unsigned char action = 0;
      if (poll(&ready, 1, 500) > 0 && read(client, &action, 1) == 1 &&
          action == 1 && instance->callback)
        instance->callback(instance->context, 2, NULL);
      close(client);
    }
  }
  return NULL;
}
void clipboard_instance_destroy(clipboard_instance *instance) {
  if (!instance)
    return;
  if (instance->has_thread) {
    unsigned char stop = 1;
    ssize_t result;
    do {
      result = write(instance->wake[1], &stop, 1);
    } while (result < 0 && errno == EINTR);
    pthread_join(instance->thread, NULL);
  }
  if (instance->server >= 0) {
    close(instance->server);
    unlink(instance->socket_path);
  }
  if (instance->wake[0] >= 0)
    close(instance->wake[0]);
  if (instance->wake[1] >= 0)
    close(instance->wake[1]);
  if (instance->lock >= 0) {
    flock(instance->lock, LOCK_UN);
    close(instance->lock);
  }
  free(instance);
}
clipboard_instance *clipboard_instance_create(const char *identity,
                                              clipboard_shell_callback callback,
                                              void *context, int *status) {
  if (status)
    *status = -1;
  if (!valid_identity(identity))
    return NULL;
  char directory[108];
  const char *runtime = getenv("XDG_RUNTIME_DIR");
  int length = runtime ? snprintf(directory, sizeof(directory),
                                  "%s/clipboard-desktop", runtime)
                       : -1;
  if (length < 0 || length >= 50 || !private_directory(directory)) {
    snprintf(directory, sizeof(directory), "/tmp/clipboard-desktop-%lu",
             (unsigned long)geteuid());
    if (!private_directory(directory))
      return NULL;
  }
  clipboard_instance *instance = calloc(1, sizeof(*instance));
  if (!instance)
    return NULL;
  instance->lock = instance->server = instance->wake[0] = instance->wake[1] =
      -1;
  instance->callback = callback;
  instance->context = context;
  char lock_path[160];
  snprintf(lock_path, sizeof(lock_path), "%s/%.40s.lock", directory, identity);
  snprintf(instance->socket_path, sizeof(instance->socket_path),
           "%s/%.40s.sock", directory, identity);
  instance->lock =
      open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  struct stat metadata;
  if (instance->lock < 0 || fstat(instance->lock, &metadata) != 0 ||
      !S_ISREG(metadata.st_mode) || metadata.st_uid != geteuid() ||
      metadata.st_nlink != 1 || (metadata.st_mode & 077) != 0) {
    clipboard_instance_destroy(instance);
    return NULL;
  }
  int acquired = flock(instance->lock, LOCK_EX | LOCK_NB) == 0;
  for (unsigned attempt = 0; !acquired && attempt < 100; ++attempt) {
    int client = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strcpy(address.sun_path, instance->socket_path);
    if (client >= 0 &&
        connect(client, (struct sockaddr *)&address, sizeof(address)) == 0) {
      unsigned char action = 1;
      int signaled = send(client, &action, 1, MSG_NOSIGNAL) == 1;
      close(client);
      if (signaled) {
        clipboard_instance_destroy(instance);
        if (status)
          *status = 0;
        return NULL;
      }
    } else if (client >= 0)
      close(client);
    usleep(10000); /* bounded startup handoff, no steady-state polling */
    acquired = flock(instance->lock, LOCK_EX | LOCK_NB) == 0;
  }
  if (!acquired) {
    clipboard_instance_destroy(instance);
    return NULL;
  }
  instance->server = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  struct sockaddr_un address = {0};
  address.sun_family = AF_UNIX;
  strcpy(address.sun_path, instance->socket_path);
  unlink(instance->socket_path); /* stale socket, only while holding the
                                    persistent lock */
  if (instance->server < 0 ||
      bind(instance->server, (struct sockaddr *)&address, sizeof(address)) !=
          0 ||
      chmod(instance->socket_path, 0600) != 0 ||
      listen(instance->server, 4) != 0 || pipe(instance->wake) != 0) {
    clipboard_instance_destroy(instance);
    return NULL;
  }
  fcntl(instance->wake[0], F_SETFD, FD_CLOEXEC);
  fcntl(instance->wake[1], F_SETFD, FD_CLOEXEC);
  if (pthread_create(&instance->thread, NULL, instance_loop, instance) != 0) {
    clipboard_instance_destroy(instance);
    return NULL;
  }
  instance->has_thread = 1;
  if (status)
    *status = 1;
  return instance;
}
#else
struct clipboard_instance {
  int unused;
};
clipboard_instance *clipboard_instance_create(const char *identity,
                                              clipboard_shell_callback callback,
                                              void *context, int *status) {
  (void)identity;
  (void)callback;
  (void)context;
  if (status)
    *status = -1;
  return NULL;
}
void clipboard_instance_destroy(clipboard_instance *instance) {
  (void)instance;
}
#endif

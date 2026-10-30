#include "desktop_services.h"
#include <stdlib.h>
#include <string.h>
void cds_free(void *value) { free(value); }
static int valid_account(const char *account) {
  if (!account || strlen(account) != 64)
    return 0;
  for (unsigned i = 0; i < 64; ++i)
    if (!((account[i] >= 'a' && account[i] <= 'f') ||
          (account[i] >= '0' && account[i] <= '9')))
      return 0;
  return 1;
}
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdio.h>
#include <wchar.h>
#include <wincred.h>
static int credential_target(const char *account, WCHAR target[128]) {
  if (!valid_account(account))
    return 0;
  char value[128];
  snprintf(value, sizeof(value), "com.clipboard.desktop.remoteAI.%s", account);
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, target,
                             128) != 0;
}
int cds_credential_read(const char *account, char **value) {
  *value = NULL;
  WCHAR target[128];
  if (!credential_target(account, target))
    return -2;
  PCREDENTIALW credential = NULL;
  if (!CredReadW(target, CRED_TYPE_GENERIC, 0, &credential))
    return GetLastError() == ERROR_NOT_FOUND ? 0 : -1;
  int result = -1;
  if (credential->CredentialBlobSize <= 4096) {
    char *copy = malloc((size_t)credential->CredentialBlobSize + 1);
    if (copy) {
      memcpy(copy, credential->CredentialBlob, credential->CredentialBlobSize);
      copy[credential->CredentialBlobSize] = 0;
      *value = copy;
      result = 1;
    }
  }
  CredFree(credential);
  return result;
}
int cds_credential_save(const char *account, const char *value) {
  WCHAR target[128];
  if (!credential_target(account, target) || !value ||
      strlen(value) > CRED_MAX_CREDENTIAL_BLOB_SIZE)
    return -2;
  CREDENTIALW credential = {0};
  credential.Type = CRED_TYPE_GENERIC;
  credential.TargetName = target;
  credential.CredentialBlob = (LPBYTE)value;
  credential.CredentialBlobSize = (DWORD)strlen(value);
  credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
  credential.UserName = L"Clipboard";
  return CredWriteW(&credential, 0) ? 1 : -1;
}
int cds_credential_delete(const char *account) {
  WCHAR target[128];
  if (!credential_target(account, target))
    return -2;
  if (CredDeleteW(target, CRED_TYPE_GENERIC, 0))
    return 1;
  return GetLastError() == ERROR_NOT_FOUND ? 1 : -1;
}
static WCHAR *wide_value(const char *value) {
  if (!value || strlen(value) > 4096)
    return NULL;
  int count =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
  if (count <= 0)
    return NULL;
  WCHAR *wide = calloc((size_t)count, sizeof(WCHAR));
  if (wide)
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, wide, count);
  return wide;
}
static const WCHAR *run_key =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
int cds_startup_read(const char *name, const char *command) {
  WCHAR *key_name = wide_value(name), *expected = wide_value(command);
  if (!key_name || !expected) {
    free(key_name);
    free(expected);
    return -2;
  }
  WCHAR actual[4096];
  DWORD size = sizeof(actual), type = 0;
  LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, run_key, key_name,
                                RRF_RT_REG_SZ, &type, actual, &size);
  int result = status == ERROR_FILE_NOT_FOUND ? 0
               : status == ERROR_SUCCESS      ? (wcscmp(actual, expected) == 0)
                                              : -1;
  free(key_name);
  free(expected);
  return result;
}
int cds_startup_set(const char *name, const char *command, int enabled) {
  WCHAR *key_name = wide_value(name), *value = wide_value(command);
  if (!key_name || !value || (enabled && wcslen(value) > 260)) {
    free(key_name);
    free(value);
    return -2;
  }
  HKEY key = NULL;
  LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, run_key, 0, NULL, 0,
                                   KEY_SET_VALUE, NULL, &key, NULL);
  if (status == ERROR_SUCCESS) {
    status = enabled
                 ? RegSetValueExW(key, key_name, 0, REG_SZ, (BYTE *)value,
                                  (DWORD)((wcslen(value) + 1) * sizeof(WCHAR)))
                 : RegDeleteValueW(key, key_name);
    RegCloseKey(key);
  }
  free(key_name);
  free(value);
  return status == ERROR_SUCCESS || (!enabled && status == ERROR_FILE_NOT_FOUND)
             ? 1
             : -1;
}
int cds_ocr(const unsigned char *data, size_t length, const char *language,
            char **text) {
  (void)data;
  (void)length;
  (void)language;
  *text = NULL;
  return -1;
}
#elif defined(__linux__)
#include <leptonica/allheaders.h>
#include <libsecret/secret.h>
#include <tesseract/capi.h>
/* The synchronous API stays off UI and is cancelled after a bounded wait. */
typedef struct secret_timeout {
  GMutex lock;
  GCond condition;
  GCancellable *cancel;
  GThread *thread;
  int done;
} secret_timeout;
static gpointer cancel_secret(gpointer value) {
  secret_timeout *timeout = value;
  gint64 deadline = g_get_monotonic_time() + 15 * G_TIME_SPAN_SECOND;
  g_mutex_lock(&timeout->lock);
  while (!timeout->done)
    if (!g_cond_wait_until(&timeout->condition, &timeout->lock, deadline))
      break;
  int expired = !timeout->done;
  g_mutex_unlock(&timeout->lock);
  if (expired)
    g_cancellable_cancel(timeout->cancel);
  return NULL;
}
static void secret_begin(secret_timeout *timeout) {
  memset(timeout, 0, sizeof(*timeout));
  g_mutex_init(&timeout->lock);
  g_cond_init(&timeout->condition);
  timeout->cancel = g_cancellable_new();
  timeout->thread =
      g_thread_new("clipboard-secret-timeout", cancel_secret, timeout);
}
static void secret_end(secret_timeout *timeout) {
  g_mutex_lock(&timeout->lock);
  timeout->done = 1;
  g_cond_signal(&timeout->condition);
  g_mutex_unlock(&timeout->lock);
  g_thread_join(timeout->thread);
  g_object_unref(timeout->cancel);
  g_cond_clear(&timeout->condition);
  g_mutex_clear(&timeout->lock);
}
static const SecretSchema credential_schema = {
    "com.clipboard.desktop.RemoteAI",
    SECRET_SCHEMA_NONE,
    {{"account", SECRET_SCHEMA_ATTRIBUTE_STRING}, {NULL, 0}}};
int cds_credential_read(const char *account, char **value) {
  *value = NULL;
  if (!valid_account(account))
    return -2;
  GError *error = NULL;
  secret_timeout timeout;
  secret_begin(&timeout);
  gchar *password = secret_password_lookup_sync(
      &credential_schema, timeout.cancel, &error, "account", account, NULL);
  secret_end(&timeout);
  if (error) {
    g_error_free(error);
    if (password)
      secret_password_free(password);
    return -1;
  }
  if (!password)
    return 0;
  size_t length = strlen(password);
  if (length > 4096) {
    secret_password_free(password);
    return -2;
  }
  char *copy = malloc(length + 1);
  if (copy)
    memcpy(copy, password, length + 1);
  secret_password_free(password);
  *value = copy;
  return copy ? 1 : -1;
}
int cds_credential_save(const char *account, const char *value) {
  if (!valid_account(account) || !value || strlen(value) > 4096)
    return -2;
  GError *error = NULL;
  secret_timeout timeout;
  secret_begin(&timeout);
  gboolean saved = secret_password_store_sync(
      &credential_schema, SECRET_COLLECTION_DEFAULT,
      "Clipboard remote AI credential", value, timeout.cancel, &error,
      "account", account, NULL);
  secret_end(&timeout);
  if (error) {
    g_error_free(error);
    return -1;
  }
  return saved ? 1 : -1;
}
int cds_credential_delete(const char *account) {
  if (!valid_account(account))
    return -2;
  GError *error = NULL;
  secret_timeout timeout;
  secret_begin(&timeout);
  secret_password_clear_sync(&credential_schema, timeout.cancel, &error,
                             "account", account, NULL);
  secret_end(&timeout);
  if (error) {
    g_error_free(error);
    return -1;
  }
  return 1;
}

int cds_startup_read(const char *name, const char *command) {
  (void)name;
  (void)command;
  return -1;
}
int cds_startup_set(const char *name, const char *command, int enabled) {
  (void)name;
  (void)command;
  (void)enabled;
  return -1;
}
int cds_ocr(const unsigned char *data, size_t length, const char *language,
            char **text) {
  *text = NULL;
  if (!data || !length || length > 16 * 1024 * 1024)
    return -2;
  l_int32 format, width, height, bps, spp, cmap;
  if (pixReadHeaderMem(data, length, &format, &width, &height, &bps, &spp,
                       &cmap) != 0 ||
      width <= 0 || height <= 0 || width > 32768 || height > 32768 ||
      (long long)width * height > 30000000)
    return -2;
  PIX *image = pixReadMem(data, length);
  if (!image)
    return -2;
  double scale = width > height ? 2400.0 / width : 2400.0 / height;
  if (scale < 1) {
    PIX *scaled = pixScale(image, (l_float32)scale, (l_float32)scale);
    pixDestroy(&image);
    image = scaled;
  }
  if (!image)
    return -2;
  TessBaseAPI *engine = TessBaseAPICreate();
  if (!engine) {
    pixDestroy(&image);
    return -1;
  }
  int result = -1;
  TessBaseAPISetVariable(engine, "debug_file", "/dev/null");
  if (TessBaseAPIInit3(engine, NULL,
                       language && *language ? language : "eng") == 0) {
    if (language && strstr(language, "chi_sim")) {
      char **loaded = TessBaseAPIGetLoadedLanguagesAsVector(engine);
      int found = 0;
      if (loaded) {
        for (unsigned i = 0; loaded[i]; ++i)
          if (!strcmp(loaded[i], "chi_sim"))
            found = 1;
        TessDeleteTextArray(loaded);
      }
      if (!found) {
        TessBaseAPIEnd(engine);
        TessBaseAPIDelete(engine);
        pixDestroy(&image);
        return -1;
      }
    }
    TessBaseAPISetPageSegMode(engine, PSM_AUTO);
    TessBaseAPISetImage2(engine, image);
    ETEXT_DESC *monitor = TessMonitorCreate();
    if (!monitor) {
      TessBaseAPIEnd(engine);
      TessBaseAPIDelete(engine);
      pixDestroy(&image);
      return -1;
    }
    TessMonitorSetDeadlineMSecs(monitor, 30000);
    int completed = TessBaseAPIRecognize(engine, monitor);
    TessMonitorDelete(monitor);
    char *recognized = completed == 0 ? TessBaseAPIGetUTF8Text(engine) : NULL;
    if (recognized) {
      size_t count = strlen(recognized);
      if (count > 32000)
        count = 32000;
      char *copy = malloc(count + 1);
      if (copy) {
        memcpy(copy, recognized, count);
        copy[count] = 0;
        *text = copy;
        result = 1;
      }
      TessDeleteText(recognized);
    }
  }
  TessBaseAPIEnd(engine);
  TessBaseAPIDelete(engine);
  pixDestroy(&image);
  return result;
}
#else
int cds_credential_read(const char *account, char **value) {
  (void)account;
  *value = NULL;
  return -1;
}
int cds_credential_save(const char *account, const char *value) {
  (void)account;
  (void)value;
  return -1;
}
int cds_credential_delete(const char *account) {
  (void)account;
  return -1;
}
int cds_startup_read(const char *name, const char *command) {
  (void)name;
  (void)command;
  return -1;
}
int cds_startup_set(const char *name, const char *command, int enabled) {
  (void)name;
  (void)command;
  (void)enabled;
  return -1;
}
int cds_ocr(const unsigned char *data, size_t length, const char *language,
            char **text) {
  (void)data;
  (void)length;
  (void)language;
  *text = NULL;
  return -1;
}
#endif

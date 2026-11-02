// Exercise the real product adapter with independently encoded valid images.
#define WIN32_LEAN_AND_MEAN
#include "desktop_clipboard.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

static unsigned failures = 0;
static void check(const char *format, int sensitive, const char *name,
                  int passed) {
  printf("%s %s_%s_%s\n", passed ? "PASS" : "FAIL", format,
         sensitive ? "sensitive" : "ordinary", name);
  if (!passed)
    ++failures;
}
static size_t read_fixture(const char *root, const char *name,
                           unsigned char *bytes, size_t capacity) {
  char path[2048];
  int length = snprintf(path, sizeof(path), "%s\\%s", root, name);
  if (length < 0 || (size_t)length >= sizeof(path))
    return 0;
  FILE *input = NULL;
  if (fopen_s(&input, path, "rb") || !input)
    return 0;
  size_t count = fread(bytes, 1, capacity, input);
  int complete = !ferror(input) && feof(input);
  fclose(input);
  return complete ? count : 0;
}
static int original_native(const cb_payload *image, UINT format) {
  if (!OpenClipboard(NULL))
    return 0;
  HANDLE value = GetClipboardData(format);
  const void *bytes = value ? GlobalLock(value) : NULL;
  int valid = bytes && GlobalSize(value) == image->length &&
              !memcmp(bytes, image->data, image->length);
  if (bytes)
    GlobalUnlock(value);
  CloseClipboard();
  return valid;
}
static int standard_bitmap(const unsigned char *expected, size_t size,
                           LONG width, LONG height) {
  if (!OpenClipboard(NULL))
    return 0;
  HANDLE value = GetClipboardData(CF_DIBV5);
  const BITMAPV5HEADER *header = value ? GlobalLock(value) : NULL;
  int valid = header && GlobalSize(value) == sizeof(*header) + size;
  if (valid)
    valid = header->bV5Size == sizeof(*header) && header->bV5Width == width &&
            header->bV5Height == -height && header->bV5Planes == 1 &&
            header->bV5BitCount == 32 &&
            header->bV5Compression == BI_BITFIELDS &&
            header->bV5SizeImage == size && header->bV5RedMask == 0x00ff0000 &&
            header->bV5GreenMask == 0x0000ff00 &&
            header->bV5BlueMask == 0x000000ff &&
            header->bV5AlphaMask == 0xff000000 &&
            (!expected || !memcmp(header + 1, expected, size));
  if (header)
    GlobalUnlock(value);
  CloseClipboard();
  return valid;
}
int main(int argc, char **argv) {
  char actions[8] = {0};
  if (GetEnvironmentVariableA("GITHUB_ACTIONS", actions, sizeof(actions)) !=
          4 ||
      strcmp(actions, "true") || argc != 2)
    return 2;
  cb_session *session = cb_open();
  if (!session)
    return 2;
  const char *names[] = {"jpeg", "tiff"};
  const char *files[] = {"fixture.jpeg", "fixture.tiff"};
  const char *pixels[] = {"jpeg.bgra", "tiff.bgra"};
  const int formats[] = {CB_JPEG, CB_TIFF};
  for (size_t index = 0; index < 2; ++index) {
    unsigned char raw[64 * 1024], reference[25];
    size_t length = read_fixture(argv[1], files[index], raw, sizeof(raw));
    size_t pixel_count =
        read_fixture(argv[1], pixels[index], reference, sizeof(reference));
    if (!length || pixel_count != 24) {
      cb_close(session);
      return 2;
    }
    cb_payload image = {formats[index], raw, length};
    UINT native = index == 0 ? RegisterClipboardFormatW(L"JFIF") : CF_TIFF;
    for (int sensitive = 0; sensitive <= 1; ++sensitive) {
      int written = cb_write_bundle(session, &image, 1, sensitive);
      check(names[index], sensitive, "valid_image_write", written == CB_OK);
      check(names[index], sensitive, "original_native_bytes_preserved",
            written == CB_OK && original_native(&image, native));
      check(names[index], sensitive, "standard_bitmap_available_to_receivers",
            IsClipboardFormatAvailable(CF_DIB) &&
                IsClipboardFormatAvailable(CF_DIBV5));
      check(names[index], sensitive,
            "standard_bitmap_matches_independent_gdi_pixels",
            standard_bitmap(reference, pixel_count, 3, 2));
      cb_bundle *bundle = NULL;
      int status = cb_read_bundle(session, 16 * 1024 * 1024, &bundle);
      check(names[index], sensitive,
            "original_roundtrip_without_derived_duplicate",
            status == CB_OK && bundle && bundle->count == 1 &&
                bundle->payloads[0].format == image.format &&
                bundle->payloads[0].length == image.length &&
                !memcmp(bundle->payloads[0].data, image.data, image.length));
      check(names[index], sensitive, "sensitivity_preserved",
            status == CB_OK && bundle && bundle->sensitive == sensitive);
      cb_bundle_free(bundle);
    }
    // These coordinate permutations are independent of WIC transform flags.
    // TIFF has six distinct colors; JPEG retains the unchanged uniform source
    // to avoid cross-codec chroma rounding affecting this geometry test.
    static const unsigned maps[8][6] = {{0, 1, 2, 3, 4, 5}, {2, 1, 0, 5, 4, 3},
                                        {5, 4, 3, 2, 1, 0}, {3, 4, 5, 0, 1, 2},
                                        {0, 3, 1, 4, 2, 5}, {3, 0, 4, 1, 5, 2},
                                        {5, 2, 4, 1, 3, 0}, {2, 5, 1, 4, 0, 3}};
    for (unsigned orientation = 0; orientation <= 8; ++orientation) {
      char file[64], label[64];
      if (orientation)
        snprintf(file, sizeof(file), "orientation%u.%s", orientation,
                 names[index]);
      else
        snprintf(file, sizeof(file), "%s", files[index]);
      snprintf(label, sizeof(label), "%s_orientation_%u", names[index],
               orientation);
      size_t variant_length = read_fixture(argv[1], file, raw, sizeof(raw));
      if (!variant_length) {
        cb_close(session);
        return 2;
      }
      cb_payload variant = {formats[index], raw, variant_length};
      unsigned char expected[24];
      for (unsigned pixel = 0; pixel < 6; ++pixel)
        memcpy(expected + pixel * 4,
               reference + maps[orientation ? orientation - 1 : 0][pixel] * 4,
               4);
      LONG width = orientation >= 5 ? 2 : 3, height = orientation >= 5 ? 3 : 2;
      for (int sensitive = 0; sensitive <= 1; ++sensitive) {
        int written = cb_write_bundle(session, &variant, 1, sensitive);
        check(label, sensitive, "valid_image_write", written == CB_OK);
        check(label, sensitive, "original_native_bytes_preserved",
              written == CB_OK && original_native(&variant, native));
        check(label, sensitive, "standard_bitmap_geometry",
              standard_bitmap(NULL, pixel_count, width, height));
        check(label, sensitive, "standard_bitmap_pixels",
              standard_bitmap(expected, pixel_count, width, height));
        cb_bundle *bundle = NULL;
        int status = cb_read_bundle(session, 16 * 1024 * 1024, &bundle);
        check(label, sensitive, "original_roundtrip_without_derived_duplicate",
              status == CB_OK && bundle && bundle->count == 1 &&
                  bundle->payloads[0].format == variant.format &&
                  bundle->payloads[0].length == variant.length &&
                  !memcmp(bundle->payloads[0].data, variant.data,
                          variant.length));
        check(label, sensitive, "sensitivity_preserved",
              status == CB_OK && bundle && bundle->sensitive == sensitive);
        cb_bundle_free(bundle);
      }
    }
  }
  cb_close(session);
  return failures ? 1 : 0;
}

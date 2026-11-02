// Native clipboard regression, run only on the owned Windows Actions desktop.
#define WIN32_LEAN_AND_MEAN
#include "desktop_clipboard.h"
#include <objbase.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

static unsigned char png[] = {
    137, 80,  78, 71, 13, 10,  26,  10,  0,   0,   0,   13,  73,  72,  68,  82,
    0,   0,   0,  2,  0,  0,   0,   2,   8,   6,   0,   0,   0,   114, 182, 13,
    36,  0,   0,  0,  22, 73,  68,  65,  84,  120, 156, 99,  248, 207, 192, 240,
    31,  8,   27, 24, 64, 180, 136, 134, 205, 127, 0,   56,  32,  5,   244, 53,
    131, 175, 70, 0,  0,  0,   0,   73,  69,  78,  68,  174, 66,  96,  130};
static unsigned checks = 0;
#define REQUIRE(test, name)                                                    \
  do {                                                                         \
    if (!(test)) {                                                             \
      fprintf(stderr, "FAIL %s\n", name);                                      \
      return 1;                                                                \
    }                                                                          \
    ++checks;                                                                  \
    printf("PASS %s\n", name);                                                 \
  } while (0)

static int original_and_bitmap(void) {
  if (!OpenClipboard(NULL))
    return 0;
  int valid = IsClipboardFormatAvailable(CF_DIB) &&
              IsClipboardFormatAvailable(CF_DIBV5);
  HANDLE raw = GetClipboardData(RegisterClipboardFormatW(L"PNG"));
  const void *bytes = raw ? GlobalLock(raw) : NULL;
  valid = valid && bytes && GlobalSize(raw) == sizeof(png) &&
          !memcmp(bytes, png, sizeof(png));
  if (bytes)
    GlobalUnlock(raw);
  HANDLE dib = GetClipboardData(CF_DIBV5);
  const BITMAPV5HEADER *header = dib ? GlobalLock(dib) : NULL;
  static const unsigned char expected[] = {0, 0, 255, 255, 0,  128, 0,  128,
                                           0, 0, 0,   0,   60, 40,  20, 255};
  valid =
      valid && header && GlobalSize(dib) == sizeof(*header) + sizeof(expected);
  if (valid)
    valid =
        header->bV5Size == sizeof(*header) && header->bV5Width == 2 &&
        header->bV5Height == -2 && header->bV5Planes == 1 &&
        header->bV5BitCount == 32 && header->bV5Compression == BI_BITFIELDS &&
        header->bV5RedMask == 0x00ff0000 &&
        header->bV5GreenMask == 0x0000ff00 &&
        header->bV5BlueMask == 0x000000ff &&
        header->bV5AlphaMask == 0xff000000 && header->bV5CSType == LCS_sRGB &&
        !memcmp(header + 1, expected, sizeof(expected));
  if (header)
    GlobalUnlock(dib);
  CloseClipboard();
  return valid;
}

static int single_original(cb_session *session, const cb_payload *expected,
                           int sensitive) {
  cb_bundle *bundle = NULL;
  int status = cb_read_bundle(session, 16 * 1024 * 1024, &bundle);
  int valid =
      status == CB_OK && bundle && bundle->count == 1 &&
      bundle->sensitive == sensitive && bundle->payloads[0].format == CB_PNG &&
      bundle->payloads[0].length == expected->length &&
      !memcmp(bundle->payloads[0].data, expected->data, expected->length);
  cb_bundle_free(bundle);
  return valid;
}

int main(int argc, char **argv) {
  char actions[8] = {0};
  DWORD actions_length =
      GetEnvironmentVariableA("GITHUB_ACTIONS", actions, sizeof(actions));
  if (actions_length != 4 || strcmp(actions, "true") || argc != 2)
    return 2;
  cb_session *session = cb_open();
  REQUIRE(session, "native_session");
  cb_payload image = {CB_PNG, png, sizeof(png)};
  REQUIRE(cb_write_bundle(session, &image, 1, 0) == CB_OK,
          "png_write_without_existing_com_apartment");
  REQUIRE(original_and_bitmap(),
          "original_png_and_top_down_premultiplied_alpha_dib");
  REQUIRE(single_original(session, &image, 0),
          "bitmap_does_not_duplicate_history_payload");
  ULONG_PTR token = 0;
  REQUIRE(CoGetContextToken(&token) == CO_E_NOTINITIALIZED,
          "temporary_com_apartment_is_balanced");
  REQUIRE(SUCCEEDED(CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)),
          "caller_sta");
  REQUIRE(cb_write_bundle(session, &image, 1, 1) == CB_OK &&
              original_and_bitmap() && single_original(session, &image, 1),
          "sta_png_and_sensitivity_preserved");
  REQUIRE(SUCCEEDED(CoGetContextToken(&token)),
          "caller_sta_is_not_uninitialized");
  CoUninitialize();
  REQUIRE(SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED)), "caller_mta");
  REQUIRE(cb_write_bundle(session, &image, 1, 0) == CB_OK &&
              original_and_bitmap(),
          "mta_png_and_alpha_preserved");
  CoUninitialize();
  REQUIRE(CoGetContextToken(&token) == CO_E_NOTINITIALIZED,
          "caller_mta_reference_is_balanced");

  unsigned char opaque[] = {137, 80, 78, 71, 13, 10, 26, 10, 42};
  cb_payload invalid = {CB_PNG, opaque, sizeof(opaque)};
  REQUIRE(cb_write_bundle(session, &invalid, 1, 0) == CB_OK &&
              !IsClipboardFormatAvailable(CF_DIB) &&
              single_original(session, &invalid, 0),
          "undecodable_png_keeps_original_without_bitmap");
  FILE *input = NULL;
  REQUIRE(fopen_s(&input, argv[1], "rb") == 0 && input,
          "owned_large_dimensions_fixture");
  unsigned char *large = malloc(1024 * 1024);
  REQUIRE(large, "bounded_large_fixture_buffer");
  size_t count = fread(large, 1, 1024 * 1024, input);
  int complete = !ferror(input) && feof(input);
  fclose(input);
  cb_payload oversized = {CB_PNG, large, count};
  REQUIRE(complete && count > 0 &&
              cb_write_bundle(session, &oversized, 1, 0) == CB_OK &&
              !IsClipboardFormatAvailable(CF_DIB) &&
              single_original(session, &oversized, 0),
          "decoded_bitmap_budget_keeps_compressed_original");
  free(large);

  unsigned char text[] = "fixture", html[] = "<b>fixture</b>",
                rtf[] = "{\\rtf1 fixture}";
  unsigned char jpeg[] = {255, 216, 255, 217},
                tiff[] = {73, 73, 42, 0, 8, 0, 0, 0};
  unsigned char files[] = "C:\\fixture one.txt\nC:\\fixture two.txt";
  unsigned char bmp[58] = {66, 77, 58, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0,  40,
                           0,  0,  0,  1, 0, 0, 0, 1, 0, 0, 0,  1, 0, 24, 0};
  cb_payload all[] = {
      {CB_TEXT, text, sizeof(text) - 1},    {CB_HTML, html, sizeof(html) - 1},
      {CB_RTF, rtf, sizeof(rtf) - 1},       image,
      {CB_JPEG, jpeg, sizeof(jpeg)},        {CB_BMP, bmp, sizeof(bmp)},
      {CB_FILES, files, sizeof(files) - 1}, {CB_TIFF, tiff, sizeof(tiff)}};
  REQUIRE(cb_write_bundle(session, all, 8, 1) == CB_OK && original_and_bitmap(),
          "eight_formats_plus_bitmap_and_sensitive_marker_fit");
  cb_bundle *bundle = NULL;
  REQUIRE(cb_read_bundle(session, 16 * 1024 * 1024, &bundle) == CB_OK &&
              bundle && bundle->sensitive,
          "full_bundle_keeps_sensitive_marker");
  cb_bundle_free(bundle);
  cb_close(session);
  printf("%u native Windows PNG checks passed\n", checks);
  return 0;
}

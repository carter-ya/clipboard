/* Private CPU-only image classification. Image bytes cross stdin, never paths.
 * The immutable model, labels, runtime and notices are verified by the builder.
 * The reference-tensor build is test-only and is never distributed.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <locale.h>
#include "onnxruntime_c_api.h"
#include "embedded-model.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <wincodec.h>
#include <objbase.h>
#include <fcntl.h>
#include <io.h>
#else
#include <sys/resource.h>
#ifndef CLIPBOARD_IMAGE_MODEL_CHECK
#include <leptonica/allheaders.h>
#endif
#endif

#define INPUT_LIMIT (16U * 1024U * 1024U)
#define PIXEL_LIMIT 30000000ULL
#define TENSOR_COUNT (3U * 224U * 224U)
#define CLASS_COUNT 1000U

static int limits(void) {
#ifdef _WIN32
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
  if (_setmode(_fileno(stdin), _O_BINARY) == -1 ||
      _setmode(_fileno(stdout), _O_BINARY) == -1) return 0;
  HANDLE job = CreateJobObjectW(NULL, NULL);
  if (!job) return 0;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = {0};
  info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_PROCESS_TIME;
  info.BasicLimitInformation.PerProcessUserTimeLimit.QuadPart = 10LL * 10000000LL;
  info.ProcessMemoryLimit = 512ULL * 1024ULL * 1024ULL;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info)) ||
      !AssignProcessToJobObject(job, GetCurrentProcess())) {
    CloseHandle(job); return 0;
  }
  return 1; /* Keep the unnamed job alive until this owned worker exits. */
#else
  struct rlimit memory = {512UL * 1024UL * 1024UL, 512UL * 1024UL * 1024UL};
  struct rlimit cpu = {10, 10}, core = {0, 0};
  return setrlimit(RLIMIT_AS, &memory) == 0 && setrlimit(RLIMIT_CPU, &cpu) == 0 &&
         setrlimit(RLIMIT_CORE, &core) == 0;
#endif
}

static int infer(float *input, float *scores) {
  const OrtApi *api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
  if (!api) return 0;
  OrtEnv *env = NULL;
  OrtSessionOptions *options = NULL;
  OrtSession *session = NULL;
  OrtMemoryInfo *memory = NULL;
  OrtValue *value = NULL, *output = NULL;
  OrtTensorTypeAndShapeInfo *shape = NULL;
  OrtAllocator *allocator = NULL;
  char *input_name = NULL, *output_name = NULL;
  int success = 0;
#define CHECK(call) do { OrtStatus *error = (call); if (error) { api->ReleaseStatus(error); goto done; } } while (0)
  CHECK(api->CreateEnv(ORT_LOGGING_LEVEL_FATAL, "clipboard-image", &env));
  CHECK(api->DisableTelemetryEvents(env));
  CHECK(api->CreateSessionOptions(&options));
  CHECK(api->SetSessionExecutionMode(options, ORT_SEQUENTIAL));
  CHECK(api->SetIntraOpNumThreads(options, 1));
  CHECK(api->SetInterOpNumThreads(options, 1));
  CHECK(api->DisableCpuMemArena(options));
  CHECK(api->DisableMemPattern(options));
  CHECK(api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_BASIC));
  /* No provider auto-selection, custom operators, model paths or external data. */
  CHECK(api->CreateSessionFromArray(env, embedded_model, sizeof(embedded_model) - 1, options, &session));
  CHECK(api->GetAllocatorWithDefaultOptions(&allocator));
  CHECK(api->SessionGetInputName(session, 0, allocator, &input_name));
  CHECK(api->SessionGetOutputName(session, 0, allocator, &output_name));
  CHECK(api->CreateCpuMemoryInfo(OrtDeviceAllocator, OrtMemTypeDefault, &memory));
  const int64_t dimensions[] = {1, 3, 224, 224};
  CHECK(api->CreateTensorWithDataAsOrtValue(memory, input, TENSOR_COUNT * sizeof(float),
      dimensions, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &value));
  const char *inputs[] = {input_name}, *outputs[] = {output_name};
  CHECK(api->Run(session, NULL, inputs, (const OrtValue *const *)&value, 1, outputs, 1, &output));
  CHECK(api->GetTensorTypeAndShape(output, &shape));
  size_t count = 0;
  ONNXTensorElementDataType type;
  CHECK(api->GetTensorShapeElementCount(shape, &count));
  CHECK(api->GetTensorElementType(shape, &type));
  if (count != CLASS_COUNT || type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) goto done;
  float *data = NULL;
  CHECK(api->GetTensorMutableData(output, (void **)&data));
  if (!data) goto done;
  memcpy(scores, data, CLASS_COUNT * sizeof(float));
  success = 1;
done:
  if (allocator && input_name) allocator->Free(allocator, input_name);
  if (allocator && output_name) allocator->Free(allocator, output_name);
  if (shape) api->ReleaseTensorTypeAndShapeInfo(shape);
  if (output) api->ReleaseValue(output);
  if (value) api->ReleaseValue(value);
  if (memory) api->ReleaseMemoryInfo(memory);
  if (session) api->ReleaseSession(session);
  if (options) api->ReleaseSessionOptions(options);
  if (env) api->ReleaseEnv(env);
#undef CHECK
  return success;
}

#ifndef CLIPBOARD_IMAGE_MODEL_CHECK
typedef struct pixels {
  int width, height;
#ifdef _WIN32
  unsigned char *rgb;
#else
  PIX *image;
#endif
} pixels;

static int valid_dimensions(unsigned width, unsigned height) {
  return width > 0 && height > 0 && width <= 32768 && height <= 32768 &&
         (uint64_t)width * height <= PIXEL_LIMIT;
}

static int decode(const unsigned char *bytes, size_t count, pixels *result) {
#ifdef _WIN32
  IWICImagingFactory *factory = NULL;
  IWICStream *stream = NULL;
  IWICBitmapDecoder *decoder = NULL;
  IWICBitmapFrameDecode *frame = NULL;
  IWICFormatConverter *converter = NULL;
  unsigned width = 0, height = 0;
  int success = 0;
  HRESULT initialized = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return 0;
#define WIC(call) do { if (FAILED(call)) goto done; } while (0)
  WIC(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
      &IID_IWICImagingFactory, (void **)&factory));
  WIC(IWICImagingFactory_CreateStream(factory, &stream));
  WIC(IWICStream_InitializeFromMemory(stream, (BYTE *)bytes, (DWORD)count));
  WIC(IWICImagingFactory_CreateDecoderFromStream(factory, (IStream *)stream, NULL,
      WICDecodeMetadataCacheOnDemand, &decoder));
  WIC(IWICBitmapDecoder_GetFrame(decoder, 0, &frame));
  WIC(IWICBitmapFrameDecode_GetSize(frame, &width, &height));
  if (!valid_dimensions(width, height)) goto done;
  WIC(IWICImagingFactory_CreateFormatConverter(factory, &converter));
  WIC(IWICFormatConverter_Initialize(converter, (IWICBitmapSource *)frame,
      &GUID_WICPixelFormat24bppRGB, WICBitmapDitherTypeNone, NULL, 0,
      WICBitmapPaletteTypeCustom));
  result->rgb = malloc((size_t)width * height * 3);
  if (!result->rgb) goto done;
  WIC(IWICFormatConverter_CopyPixels(converter, NULL, width * 3,
      width * height * 3, result->rgb));
  result->width = (int)width; result->height = (int)height; success = 1;
done:
  if (converter) IWICFormatConverter_Release(converter);
  if (frame) IWICBitmapFrameDecode_Release(frame);
  if (decoder) IWICBitmapDecoder_Release(decoder);
  if (stream) IWICStream_Release(stream);
  if (factory) IWICImagingFactory_Release(factory);
  CoUninitialize();
  if (!success) { free(result->rgb); result->rgb = NULL; }
#undef WIC
  return success;
#else
  l_int32 format, width, height, bps, spp, cmap;
  if (pixReadHeaderMem(bytes, count, &format, &width, &height, &bps, &spp, &cmap) ||
      !valid_dimensions((unsigned)width, (unsigned)height)) return 0;
  PIX *image = pixReadMem(bytes, count);
  if (!image) return 0;
  result->image = pixConvertTo32(image);
  pixDestroy(&image);
  if (!result->image) return 0;
  result->width = pixGetWidth(result->image); result->height = pixGetHeight(result->image);
  if (!valid_dimensions((unsigned)result->width, (unsigned)result->height)) {
    pixDestroy(&result->image); return 0;
  }
  return 1;
#endif
}

static unsigned char component(const pixels *image, int x, int y, int channel) {
#ifdef _WIN32
  return image->rgb[((size_t)y * image->width + x) * 3 + channel];
#else
  l_uint32 pixel = 0;
  l_int32 red, green, blue;
  pixGetPixel(image->image, x, y, &pixel);
  extractRGBValues(pixel, &red, &green, &blue);
  return (unsigned char)(channel == 0 ? red : channel == 1 ? green : blue);
#endif
}

static void prepare(const pixels *image, float *tensor) {
  const double means[] = {0.485, 0.456, 0.406}, deviations[] = {0.229, 0.224, 0.225};
  double ratio = 256.0 / (image->width < image->height ? image->width : image->height);
  int width = (int)llround(image->width * ratio), height = (int)llround(image->height * ratio);
  int left = width / 2 - 112, top = height / 2 - 112;
  /* Sample the centered 224x224 crop directly; never allocate a huge resized
   * intermediate for an extremely wide/tall image. RGB bilinear interpolation
   * precedes the model's channel-first ImageNet normalization. */
  for (int y = 0; y < 224; ++y) for (int x = 0; x < 224; ++x) {
    double sx = ((left + x + 0.5) * image->width / width) - 0.5;
    double sy = ((top + y + 0.5) * image->height / height) - 0.5;
    sx = fmax(0, fmin(image->width - 1, sx)); sy = fmax(0, fmin(image->height - 1, sy));
    int x0 = (int)floor(sx), y0 = (int)floor(sy);
    int x1 = x0 + 1 < image->width ? x0 + 1 : x0, y1 = y0 + 1 < image->height ? y0 + 1 : y0;
    double dx = sx - x0, dy = sy - y0;
    for (int channel = 0; channel < 3; ++channel) {
      double upper = component(image, x0, y0, channel) * (1 - dx) + component(image, x1, y0, channel) * dx;
      double lower = component(image, x0, y1, channel) * (1 - dx) + component(image, x1, y1, channel) * dx;
      double value = upper * (1 - dy) + lower * dy;
      tensor[channel * 224 * 224 + y * 224 + x] = (float)((value / 255 - means[channel]) / deviations[channel]);
    }
  }
}

static void json_name(const char *name) {
  putchar('"');
  for (const unsigned char *at = (const unsigned char *)name; *at; ++at) {
    if (*at == '"' || *at == '\\') putchar('\\');
    putchar(*at);
  }
  putchar('"');
}
#endif

int main(void) {
  if (!limits() || !setlocale(LC_NUMERIC, "C")) return 2;
  float *tensor = malloc(TENSOR_COUNT * sizeof(float)), scores[CLASS_COUNT];
  if (!tensor) return 2;
#ifdef CLIPBOARD_IMAGE_MODEL_CHECK
  unsigned char extra;
  if (fread(tensor, sizeof(float), TENSOR_COUNT, stdin) != TENSOR_COUNT ||
      fread(&extra, 1, 1, stdin) || ferror(stdin)) { free(tensor); return 3; }
  int success = infer(tensor, scores);
  free(tensor);
  return success && fwrite(scores, sizeof(float), CLASS_COUNT, stdout) == CLASS_COUNT && !fflush(stdout) ? 0 : 4;
#else
  unsigned char *input = malloc(INPUT_LIMIT + 1);
  if (!input) { free(tensor); return 2; }
  size_t count = fread(input, 1, INPUT_LIMIT + 1, stdin);
  if (ferror(stdin) || count > INPUT_LIMIT) { free(input); free(tensor); return 3; }
  pixels image = {0};
  if (!count || !decode(input, count, &image)) { free(input); free(tensor); return 4; }
  free(input);
  prepare(&image, tensor);
#ifdef _WIN32
  free(image.rgb);
#else
  pixDestroy(&image.image);
#endif
  int success = infer(tensor, scores);
  free(tensor);
  if (!success) return 4;
  double maximum = -INFINITY, sum = 0, probabilities[CLASS_COUNT];
  for (size_t i = 0; i < CLASS_COUNT; ++i) {
    if (!isfinite(scores[i])) return 4;
    if (scores[i] > maximum) maximum = scores[i];
  }
  for (size_t i = 0; i < CLASS_COUNT; ++i) { probabilities[i] = exp(scores[i] - maximum); sum += probabilities[i]; }
  if (!isfinite(sum) || sum <= 0) return 4;
  printf("{\"width\":%d,\"height\":%d,\"labels\":[", image.width, image.height);
  for (int rank = 0; rank < 3; ++rank) {
    size_t best = 0;
    for (size_t i = 1; i < CLASS_COUNT; ++i) if (probabilities[i] > probabilities[best]) best = i;
    double confidence = probabilities[best] / sum;
    if (confidence < 0.1) break;
    if (rank) putchar(',');
    printf("{\"name\":"); json_name(class_names[best]);
    printf(",\"confidence\":%.9g}", confidence); probabilities[best] = -1;
  }
  puts("]}");
  return ferror(stdout) || fflush(stdout) ? 4 : 0;
#endif
}

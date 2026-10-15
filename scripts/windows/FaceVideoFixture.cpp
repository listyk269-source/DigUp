// Test-only fixture generator. Uses Windows' local WIC decoder and Media
// Foundation H.264 encoder; it is never shipped as an application dependency.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <wincodec.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <codecapi.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {
constexpr UINT32 width = 960;
constexpr UINT32 height = 754;
constexpr UINT32 fps = 5;
constexpr UINT32 frames = 30;
constexpr LONGLONG frame_duration = 10000000 / fps;

void check(HRESULT result, const char* stage) {
    if (FAILED(result)) {
        char message[256]{};
        std::snprintf(message, sizeof(message), "%s failed (HRESULT 0x%08lX)", stage, static_cast<unsigned long>(result));
        throw std::runtime_error(message);
    }
}

struct Platform {
    Platform() {
        check(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "COM initialization");
        HRESULT result = MFStartup(MF_VERSION, MFSTARTUP_FULL);
        if (FAILED(result)) { CoUninitialize(); check(result, "Media Foundation initialization"); }
    }
    ~Platform() { MFShutdown(); CoUninitialize(); }
    Platform(const Platform&) = delete;
    Platform& operator=(const Platform&) = delete;
};

BYTE clamp_byte(int value) { return static_cast<BYTE>(std::clamp(value, 0, 255)); }

std::vector<BYTE> image_nv12(const wchar_t* source) {
    ComPtr<IWICImagingFactory> factory;
    check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)), "WIC factory");
    ComPtr<IWICBitmapDecoder> decoder;
    check(factory->CreateDecoderFromFilename(source, nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder), "fixture image decode");
    ComPtr<IWICBitmapFrameDecode> frame;
    check(decoder->GetFrame(0, &frame), "fixture image frame");
    ComPtr<IWICBitmapScaler> scaler;
    check(factory->CreateBitmapScaler(&scaler), "WIC scaler");
    check(scaler->Initialize(frame.Get(), width, height, WICBitmapInterpolationModeFant), "fixture image scaling");
    ComPtr<IWICFormatConverter> converter;
    check(factory->CreateFormatConverter(&converter), "WIC converter");
    check(converter->Initialize(scaler.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom), "BGRA conversion");
    std::vector<BYTE> bgra(width * height * 4);
    check(converter->CopyPixels(nullptr, width * 4, static_cast<UINT>(bgra.size()), bgra.data()), "fixture pixels");
    std::vector<BYTE> nv12(width * height * 3 / 2);
    // BT.601 limited-range YUV; NV12 has full Y followed by interleaved U,V.
    for (UINT32 y = 0; y < height; ++y) {
        for (UINT32 x = 0; x < width; ++x) {
            const BYTE* p = &bgra[(y * width + x) * 4];
            nv12[y * width + x] = clamp_byte(((66 * p[2] + 129 * p[1] + 25 * p[0] + 128) >> 8) + 16);
        }
    }
    for (UINT32 y = 0; y < height; y += 2) {
        for (UINT32 x = 0; x < width; x += 2) {
            int red = 0, green = 0, blue = 0;
            for (UINT32 dy = 0; dy < 2; ++dy) {
                for (UINT32 dx = 0; dx < 2; ++dx) {
                    const BYTE* p = &bgra[((y + dy) * width + x + dx) * 4];
                    blue += p[0]; green += p[1]; red += p[2];
                }
            }
            red = (red + 2) / 4; green = (green + 2) / 4; blue = (blue + 2) / 4;
            const size_t index = width * height + (y / 2) * width + x;
            nv12[index] = clamp_byte(((-38 * red - 74 * green + 112 * blue + 128) >> 8) + 128);
            nv12[index + 1] = clamp_byte(((112 * red - 94 * green - 18 * blue + 128) >> 8) + 128);
        }
    }
    return nv12;
}

void write_video(const wchar_t* source, const wchar_t* destination) {
    Platform platform;
    auto pixels = image_nv12(source);
    std::vector<BYTE> black(width * height * 3 / 2, 128);
    std::fill(black.begin(), black.begin() + width * height, static_cast<BYTE>(16));
    ComPtr<IMFAttributes> attributes;
    check(MFCreateAttributes(&attributes, 3), "sink attributes");
    check(attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4), "MP4 container");
    check(attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, FALSE), "CPU encoder selection");
    check(attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE), "sink throttling");
    ComPtr<IMFSinkWriter> writer;
    check(MFCreateSinkWriterFromURL(destination, nullptr, attributes.Get(), &writer), "MP4 sink writer");
    ComPtr<IMFMediaType> output;
    check(MFCreateMediaType(&output), "output media type");
    check(output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video), "output video type");
    check(output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264), "H.264 output");
    check(output->SetUINT32(MF_MT_AVG_BITRATE, 2000000), "H.264 bitrate");
    check(output->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive), "progressive output");
    check(output->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main), "H.264 main profile");
    check(MFSetAttributeSize(output.Get(), MF_MT_FRAME_SIZE, width, height), "output dimensions");
    check(MFSetAttributeRatio(output.Get(), MF_MT_FRAME_RATE, fps, 1), "output frame rate");
    check(MFSetAttributeRatio(output.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1), "output pixel aspect");
    DWORD stream = 0;
    check(writer->AddStream(output.Get(), &stream), "H.264 stream");
    ComPtr<IMFMediaType> input;
    check(MFCreateMediaType(&input), "input media type");
    check(input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video), "input video type");
    check(input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12), "NV12 input");
    check(input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive), "progressive input");
    check(input->SetUINT32(MF_MT_DEFAULT_STRIDE, width), "NV12 stride");
    check(input->SetUINT32(MF_MT_FIXED_SIZE_SAMPLES, TRUE), "fixed-size samples");
    check(input->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE), "independent input samples");
    check(input->SetUINT32(MF_MT_SAMPLE_SIZE, static_cast<UINT32>(pixels.size())), "NV12 sample size");
    check(MFSetAttributeSize(input.Get(), MF_MT_FRAME_SIZE, width, height), "input dimensions");
    check(MFSetAttributeRatio(input.Get(), MF_MT_FRAME_RATE, fps, 1), "input frame rate");
    check(MFSetAttributeRatio(input.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1), "input pixel aspect");
    check(writer->SetInputMediaType(stream, input.Get(), nullptr), "encoder input");
    check(writer->BeginWriting(), "begin encoding");
    for (UINT32 index = 0; index < frames; ++index) {
        const auto& current = index < 2 * fps ? black : pixels;
        ComPtr<IMFMediaBuffer> buffer;
        check(MFCreateMemoryBuffer(static_cast<DWORD>(current.size()), &buffer), "frame buffer");
        BYTE* destination_bytes = nullptr;
        check(buffer->Lock(&destination_bytes, nullptr, nullptr), "frame buffer lock");
        std::memcpy(destination_bytes, current.data(), current.size());
        check(buffer->Unlock(), "frame buffer unlock");
        check(buffer->SetCurrentLength(static_cast<DWORD>(current.size())), "frame length");
        ComPtr<IMFSample> sample;
        check(MFCreateSample(&sample), "video sample");
        check(sample->AddBuffer(buffer.Get()), "sample buffer");
        check(sample->SetSampleTime(index * frame_duration), "sample time");
        check(sample->SetSampleDuration(frame_duration), "sample duration");
        check(writer->WriteSample(stream, sample.Get()), "H.264 encoding");
    }
    check(writer->Finalize(), "MP4 finalization");
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc != 3) { std::fputs("Usage: FaceVideoFixture.exe INPUT_JPEG OUTPUT_MP4\n", stderr); return 2; }
    try {
        write_video(argv[1], argv[2]);
        std::puts("Generated H.264/MP4: 960x754, 5 fps, 6 seconds, first 2 seconds black.");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
}

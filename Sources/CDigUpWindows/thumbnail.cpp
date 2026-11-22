#include "CDigUpWindows.h"
#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>

using Microsoft::WRL::ComPtr;

static HRESULT decode(const WCHAR *path, UINT limit, BYTE *pixels, UINT *width, UINT *height) {
    ComPtr<IWICImagingFactory> factory;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&factory));
    if (FAILED(hr)) return hr;
    ComPtr<IWICStream> stream;
    if (FAILED(hr = factory->CreateStream(&stream))) return hr;
    if (FAILED(hr = stream->InitializeFromFilename(path, GENERIC_READ))) return hr;
    ComPtr<IWICBitmapDecoder> decoder;
    if (FAILED(hr = factory->CreateDecoder(GUID_ContainerFormatJpeg, &GUID_VendorMicrosoft, &decoder))) return hr;
    if (FAILED(hr = decoder->Initialize(stream.Get(), WICDecodeMetadataCacheOnDemand))) return hr;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(hr = decoder->GetFrame(0, &frame))) return hr;
    UINT w, h;
    if (FAILED(hr = frame->GetSize(&w, &h))) return hr;
    if (!w || !h) return E_INVALIDARG;
    const double factor = (std::min)(1.0, double(limit) / (std::max)(w, h));
    *width = (std::max)(1U, UINT(std::round(w * factor)));
    *height = (std::max)(1U, UINT(std::round(h * factor)));
    // The scaler negotiates reduced-resolution decoding with the native JPEG codec.
    ComPtr<IWICBitmapScaler> scaler;
    if (FAILED(hr = factory->CreateBitmapScaler(&scaler))) return hr;
    if (FAILED(hr = scaler->Initialize(frame.Get(), *width, *height, WICBitmapInterpolationModeFant))) return hr;
    ComPtr<IWICFormatConverter> rgb;
    if (FAILED(hr = factory->CreateFormatConverter(&rgb))) return hr;
    if (FAILED(hr = rgb->Initialize(scaler.Get(), GUID_WICPixelFormat24bppRGB,
                                    WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom))) return hr;
    return rgb->CopyPixels(nullptr, *width * 3, *width * *height * 3, pixels);
}

int digup_jpeg_thumbnail(const uint16_t *path, unsigned limit, uint8_t *rgb,
                         unsigned *width, unsigned *height) {
    if (!limit || limit > 128) return 0;
    HRESULT apartment = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE) return 0;
    HRESULT result = decode(reinterpret_cast<const WCHAR *>(path), limit, rgb, width, height);
    if (SUCCEEDED(apartment)) CoUninitialize();
    return SUCCEEDED(result);
}

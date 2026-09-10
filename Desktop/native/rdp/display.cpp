#include "serverdash_rdp.h"
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <freerdp/freerdp.h>
#include <memory>
#include <new>

using Microsoft::WRL::ComPtr;
struct sd_rdp_display {
    HWND child{};
    DWORD thread{GetCurrentThreadId()};
    uint64_t generation{};
    uint32_t width{1}, height{1};
    bool visible{false};
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGISwapChain1> swap;
    ~sd_rdp_display() { swap.Reset(); context.Reset(); device.Reset(); if (child) DestroyWindow(child); }
};
static bool owner(sd_rdp_display* d) { return d && d->thread == GetCurrentThreadId(); }
uint32_t sd_rdp_abi_version() { return 1; }
const char* sd_rdp_engine_version() { return freerdp_get_version_string(); }
int32_t sd_rdp_display_create(uintptr_t parent, uint64_t generation, sd_rdp_display** result) {
    if (!result) return E_POINTER;
    *result = nullptr;
    if (!IsWindow(reinterpret_cast<HWND>(parent)) || !generation) return E_INVALIDARG;
    auto d = std::unique_ptr<sd_rdp_display>(new (std::nothrow) sd_rdp_display());
    if (!d) return E_OUTOFMEMORY;
    d->generation = generation;
    // Input forwarding is deliberately not enabled until the connection adapter owns focus.
    d->child = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_CLIPSIBLINGS | WS_DISABLED,
        0, 0, 1, 1, reinterpret_cast<HWND>(parent), nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!d->child) return HRESULT_FROM_WIN32(GetLastError());
    auto hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr, 0, D3D11_SDK_VERSION, &d->device, nullptr, &d->context);
    if (FAILED(hr)) hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr, 0, D3D11_SDK_VERSION, &d->device, nullptr, &d->context);
    if (FAILED(hr)) return hr;
    ComPtr<IDXGIDevice> dxgi; ComPtr<IDXGIAdapter> adapter; ComPtr<IDXGIFactory2> factory;
    if (FAILED(hr = d->device.As(&dxgi)) || FAILED(hr = dxgi->GetAdapter(&adapter)) ||
        FAILED(hr = adapter->GetParent(IID_PPV_ARGS(&factory)))) return hr;
    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = desc.Height = 1; desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2; desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.Scaling = DXGI_SCALING_STRETCH; desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    if (FAILED(hr = factory->CreateSwapChainForHwnd(d->device.Get(), d->child, &desc, nullptr, nullptr, &d->swap))) return hr;
    factory->MakeWindowAssociation(d->child, DXGI_MWA_NO_ALT_ENTER);
    *result = d.release(); return S_OK;
}
int32_t sd_rdp_display_layout(sd_rdp_display* d, int32_t x, int32_t y, uint32_t w, uint32_t h, int visible) {
    if (!owner(d)) return E_INVALIDARG;
    if (w > 16384 || h > 16384) return E_INVALIDARG;
    d->visible = visible && w && h;
    if (!SetWindowPos(d->child, nullptr, x, y, static_cast<int>(w), static_cast<int>(h), SWP_NOZORDER | SWP_NOACTIVATE))
        return HRESULT_FROM_WIN32(GetLastError());
    ShowWindow(d->child, d->visible ? SW_SHOWNOACTIVATE : SW_HIDE);
    return S_OK;
}
int32_t sd_rdp_display_frame(sd_rdp_display* d, uint64_t generation, const uint8_t* bytes, uint32_t w, uint32_t h, uint32_t stride) {
    if (!owner(d) || generation != d->generation || !bytes || !w || !h || w > 8192 || h > 8192 || stride < w * 4 || stride > 131072) return E_INVALIDARG;
    HRESULT hr;
    if (d->width != w || d->height != h) {
        if (FAILED(hr = d->swap->ResizeBuffers(2, w, h, DXGI_FORMAT_B8G8R8A8_UNORM, 0))) return hr;
        d->width = w; d->height = h;
    }
    ComPtr<ID3D11Texture2D> back;
    if (FAILED(hr = d->swap->GetBuffer(0, IID_PPV_ARGS(&back)))) return hr;
    d->context->UpdateSubresource(back.Get(), 0, nullptr, bytes, stride, 0);
    return d->swap->Present(d->visible ? 1 : 0, 0);
}
int32_t sd_rdp_display_destroy(sd_rdp_display* d) {
    if (!owner(d)) return E_INVALIDARG;
    delete d; return S_OK;
}

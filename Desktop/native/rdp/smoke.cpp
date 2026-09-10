#include "serverdash_rdp.h"
#include <windows.h>
#include <cstring>
#include <vector>
int main() {
    if (sd_rdp_abi_version() != 1 || !sd_rdp_engine_version() || std::strncmp(sd_rdp_engine_version(), "3.31.0", 6)) return 1;
    HWND parent = CreateWindowExW(0, L"STATIC", L"ServerDash native display smoke", WS_OVERLAPPEDWINDOW,
        0, 0, 640, 480, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!parent) return 2;
    sd_rdp_display* display = nullptr;
    if (sd_rdp_display_create(reinterpret_cast<uintptr_t>(parent), 7, &display) < 0) return 3;
    std::vector<uint8_t> pixels(64 * 32 * 4, 128);
    int result = 0;
    if (sd_rdp_display_layout(display, 8, 8, 320, 160, 0) < 0 ||
        sd_rdp_display_frame(display, 7, pixels.data(), 64, 32, 256) < 0 ||
        sd_rdp_display_frame(display, 6, pixels.data(), 64, 32, 256) >= 0 ||
        sd_rdp_display_frame(display, 7, pixels.data(), 64, 32, 1) >= 0 ||
        sd_rdp_display_layout(display, 0, 0, 640, 480, 1) < 0 ||
        sd_rdp_display_layout(display, 0, 0, 0, 0, 0) < 0) result = 4;
    if (sd_rdp_display_destroy(display) < 0) result = 5;
    DestroyWindow(parent); return result;
}

#ifndef SERVERDASH_RDP_H
#define SERVERDASH_RDP_H
#include <stdint.h>
#if defined(_WIN32)
# if defined(SD_RDP_BUILD)
#  define SD_RDP_API __declspec(dllexport)
# else
#  define SD_RDP_API __declspec(dllimport)
# endif
#else
# define SD_RDP_API
#endif
#ifdef __cplusplus
extern "C" {
#endif
/* ABI 1: all calls occur on the owning UI thread. Pixels stay in native memory.
 * parent is the platform window handle (HWND on Windows). The caller owns it.
 * display owns its child window/device; destroying it does not close a connection.
 * BGRA rows must contain width*4 bytes. The caller retains ownership of input bytes.
 * A hidden display retains its last frame. Switching tabs/modal UI must hide it.
 */
typedef struct sd_rdp_display sd_rdp_display;
SD_RDP_API uint32_t sd_rdp_abi_version(void);
SD_RDP_API const char* sd_rdp_engine_version(void);
SD_RDP_API int32_t sd_rdp_display_create(uintptr_t parent, uint64_t generation, sd_rdp_display** result);
SD_RDP_API int32_t sd_rdp_display_layout(sd_rdp_display*, int32_t x, int32_t y, uint32_t width, uint32_t height, int visible);
SD_RDP_API int32_t sd_rdp_display_frame(sd_rdp_display*, uint64_t generation, const uint8_t* bgra, uint32_t width, uint32_t height, uint32_t stride);
SD_RDP_API int32_t sd_rdp_display_destroy(sd_rdp_display*);
#ifdef __cplusplus
}
#endif
#endif

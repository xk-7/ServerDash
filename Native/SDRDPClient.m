#import "SDRDPClient.h"
#import <AppKit/AppKit.h>
#include <pthread.h>
#include <stdatomic.h>
#define REFIID WINPR_REFIID
#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/channels/channels.h>
#include <freerdp/input.h>
#include <freerdp/error.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
extern PVIRTUALCHANNELENTRY SDRDPAddinProvider(LPCSTR name, LPCSTR subsystem, LPCSTR type, DWORD flags);

BOOL SDRDPCertificateIsSelfSigned(NSData *pem) {
    if (!pem.length || pem.length > 1024 * 1024) return NO;
    BIO *bio = BIO_new_mem_buf(pem.bytes, (int)pem.length);
    if (!bio) return NO;
    X509 *certificate = PEM_read_bio_X509(bio, NULL, NULL, NULL);
    EVP_PKEY *key = certificate ? X509_get_pubkey(certificate) : NULL;
    BOOL valid = key && X509_NAME_cmp(X509_get_issuer_name(certificate), X509_get_subject_name(certificate)) == 0 &&
        X509_verify(certificate, key) == 1;
    EVP_PKEY_free(key); X509_free(certificate); BIO_free(bio);
    return valid;
}

static const size_t SDMaximumPixels = 32 * 1024 * 1024;
static const uint32_t SDFileFormat = 0xC001;
typedef struct {
    rdpContext context;
    void *owner;
} SDContext;

@interface SDRDPClient () {
@public
    freerdp *_instance;
    pthread_mutex_t _frameLock;
    NSLock *_lifetimeLock;
    NSLock *_commandLock;
    NSMutableArray *_commands;
    atomic_bool _cancelled;
    atomic_bool _connected;
    atomic_uint _openFiles;
    BOOL _paintLocked;
    BOOL _dirty;
    BOOL _fullFrame;
    CGRect _dirtyRect;
    uint64_t _frameSequence;
    CliprdrClientContext *_clipboard;
    DispClientContext *_display;
    uint32_t _maximumMonitors;
    uint64_t _maximumMonitorArea;
    uint32_t _remoteFileFormat;
    uint32_t _requestedFormat;
    uint32_t _pendingFormat;
    uint64_t _clipboardRevision;
    uint64_t _requestedClipboardRevision;
    uint32_t _serverClipboardFlags;
    BOOL _announcedText;
    BOOL _announcedFiles;
    NSDictionary *_configuration;
    NSString *_password;
}
@end

static SDRDPClient *owner(rdpContext *context) { return (__bridge SDRDPClient *)((SDContext *)context)->owner; }
NSDictionary *SDRDPShareForContext(rdpContext *context, const char *name) {
    for (NSDictionary *share in owner(context)->_configuration[@"shares"]) if ([share[@"name"] isEqual:@(name)]) return share;
    return nil;
}
void SDRDPFileOpened(rdpContext *context) { atomic_fetch_add(&owner(context)->_openFiles, 1); }
void SDRDPFileClosed(rdpContext *context) { atomic_fetch_sub(&owner(context)->_openFiles, 1); }
static BOOL validSize(UINT32 width, UINT32 height) {
    return width >= 200 && height >= 200 && width <= 32766 && height <= 32766 &&
           (uint64_t)width * height <= SDMaximumPixels;
}
static BOOL beginPaint(rdpContext *context) {
    SDRDPClient *client = owner(context);
    if (client->_paintLocked) return FALSE;
    pthread_mutex_lock(&client->_frameLock);
    client->_paintLocked = YES;
    if (context->gdi && context->gdi->primary) context->gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}
static BOOL endPaint(rdpContext *context) {
    SDRDPClient *client = owner(context);
    if (context->gdi && context->gdi->primary && !context->gdi->primary->hdc->hwnd->invalid->null) {
        HGDI_RGN invalid = context->gdi->primary->hdc->hwnd->invalid;
        CGRect region = CGRectIntersection(CGRectMake(invalid->x, invalid->y, invalid->w, invalid->h),
                                           CGRectMake(0, 0, context->gdi->width, context->gdi->height));
        client->_dirtyRect = client->_dirty ? CGRectUnion(client->_dirtyRect, region) : region;
        client->_dirty = YES;
    }
    if (client->_paintLocked) { client->_paintLocked = NO; pthread_mutex_unlock(&client->_frameLock); }
    return TRUE;
}
static BOOL desktopResize(rdpContext *context) {
    SDRDPClient *client = owner(context);
    UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!validSize(width, height)) return FALSE;
    pthread_mutex_lock(&client->_frameLock);
    BOOL result = gdi_resize(context->gdi, width, height);
    client->_dirty = YES; client->_fullFrame = YES;
    pthread_mutex_unlock(&client->_frameLock);
    return result;
}
static int verifyCertificate(freerdp *instance, const BYTE *pem, size_t size, const char *host, UINT16 port, DWORD flags) {
    SDRDPClient *client = owner(instance->context);
    if (atomic_load(&client->_cancelled) || !pem || size == 0 || size > 1024 * 1024 ||
        flags & (VERIFY_CERT_FLAG_GATEWAY | VERIFY_CERT_FLAG_REDIRECT)) return 0;
    if (!client.verifyCertificate) return 0;
    return client.verifyCertificate([NSData dataWithBytes:pem length:size], @(host), port) &&
        !atomic_load(&client->_cancelled) ? 1 : 0;
}
static BOOL noRedirect(freerdp *instance) { return FALSE; }
static BOOL noAuthentication(freerdp *instance, char **username, char **password, char **domain, rdp_auth_reason reason) {
    // Credentials were provided in the immutable request. Never prompt/fallback inside FreeRDP.
    return reason == AUTH_NLA && username && *username && password && *password;
}
static UINT clipCapabilities(CliprdrClientContext *clip, const CLIPRDR_CAPABILITIES *caps) {
    SDRDPClient *client = owner(clip->rdpcontext);
    // FreeRDP 3.31 emits one already-decoded general capability per callback.
    if (caps->cCapabilitiesSets != 1 || !caps->capabilitySets ||
        caps->capabilitySets->capabilitySetType != CB_CAPSTYPE_GENERAL ||
        caps->capabilitySets->capabilitySetLength != CB_CAPSTYPE_GENERAL_LEN) return ERROR_INVALID_DATA;
    client->_serverClipboardFlags = ((const CLIPRDR_GENERAL_CAPABILITY_SET *)caps->capabilitySets)->generalFlags;
    return CHANNEL_RC_OK;
}
static UINT clipReady(CliprdrClientContext *clip, const CLIPRDR_MONITOR_READY *ready) {
    SDRDPClient *client = owner(clip->rdpcontext);
    CLIPRDR_GENERAL_CAPABILITY_SET general = { CB_CAPSTYPE_GENERAL, CB_CAPSTYPE_GENERAL_LEN, CB_CAPS_VERSION_2,
        CB_USE_LONG_FORMAT_NAMES | CB_STREAM_FILECLIP_ENABLED | CB_FILECLIP_NO_FILE_PATHS };
    CLIPRDR_CAPABILITIES caps = {0}; caps.cCapabilitiesSets = 1; caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    UINT result = clip->ClientCapabilities(clip, &caps);
    if (result != CHANNEL_RC_OK) return result;
    CLIPRDR_FORMAT_LIST list = {0};
    client->_announcedText = client->_announcedFiles = NO;
    return clip->ClientFormatList(clip, &list); // Never publish the existing local clipboard on connect.
}
static UINT clipFormatList(CliprdrClientContext *clip, const CLIPRDR_FORMAT_LIST *list) {
    SDRDPClient *client = owner(clip->rdpcontext);
    if (list->numFormats > 256) return ERROR_INVALID_DATA;
    client->_clipboardRevision++;
    client->_remoteFileFormat = 0;
    BOOL hasText = NO;
    for (UINT32 index = 0; index < list->numFormats; index++) {
        const CLIPRDR_FORMAT *format = &list->formats[index];
        if (format->formatId == CF_UNICODETEXT) hasText = YES;
        if (format->formatName && !strcmp(format->formatName, "FileGroupDescriptorW")) client->_remoteFileFormat = format->formatId;
    }
    CLIPRDR_FORMAT_LIST_RESPONSE response = {0}; response.common.msgFlags = CB_RESPONSE_OK;
    UINT result = clip->ClientFormatListResponse(clip, &response);
    if (client.clipboardFormats) client.clipboardFormats(client->_remoteFileFormat);
    // A file clipboard may also contain the source path as text. Never replace its file promises with that text.
    if (hasText && !client->_remoteFileFormat && [client->_configuration[@"textClipboard"] boolValue]) [client requestClipboard:CF_UNICODETEXT];
    return result;
}
static UINT clipListResponse(CliprdrClientContext *clip, const CLIPRDR_FORMAT_LIST_RESPONSE *response) { return CHANNEL_RC_OK; }
static UINT clipDataRequest(CliprdrClientContext *clip, const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    SDRDPClient *client = owner(clip->rdpcontext);
    NSData *data = nil;
    if ((request->requestedFormatId == CF_UNICODETEXT && client->_announcedText) ||
        (request->requestedFormatId == SDFileFormat && client->_announcedFiles)) {
        if (client.clipboardRequested) data = client.clipboardRequested(request->requestedFormatId);
    }
    if (data.length > 16 * 1024 * 1024) data = nil;
    CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
    response.common.msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    response.common.dataLen = (UINT32)data.length; response.requestedFormatData = data.bytes;
    return clip->ClientFormatDataResponse(clip, &response);
}
static UINT clipDataResponse(CliprdrClientContext *clip, const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    SDRDPClient *client = owner(clip->rdpcontext);
    if (response->common.dataLen > 16 * 1024 * 1024 || (response->common.dataLen && !response->requestedFormatData)) return ERROR_INVALID_DATA;
    if (client->_requestedClipboardRevision == client->_clipboardRevision &&
        (response->common.msgFlags & CB_RESPONSE_OK) && client.clipboardReceived)
        client.clipboardReceived([NSData dataWithBytes:response->requestedFormatData length:response->common.dataLen], client->_requestedFormat);
    client->_requestedFormat = 0;
    if (client->_pendingFormat) {
        uint32_t pending = client->_pendingFormat; client->_pendingFormat = 0;
        [client requestClipboard:pending];
    }
    return CHANNEL_RC_OK;
}
static UINT clipFileRequest(CliprdrClientContext *clip, const CLIPRDR_FILE_CONTENTS_REQUEST *request) {
    SDRDPClient *client = owner(clip->rdpcontext);
    NSData *data = nil;
    if (client->_announcedFiles && client.fileRequested && request->cbRequested <= 1024 * 1024 &&
        (request->dwFlags == FILECONTENTS_SIZE || request->dwFlags == FILECONTENTS_RANGE)) {
        uint64_t offset = ((uint64_t)request->nPositionHigh << 32) | request->nPositionLow;
        data = client.fileRequested(request->listIndex, offset, request->cbRequested, request->dwFlags == FILECONTENTS_SIZE);
    }
    if (data.length > 1024 * 1024) data = nil;
    CLIPRDR_FILE_CONTENTS_RESPONSE response = {0}; response.streamId = request->streamId;
    response.common.msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    response.cbRequested = (UINT32)data.length; response.requestedData = data.bytes;
    return clip->ClientFileContentsResponse(clip, &response);
}
static UINT clipFileResponse(CliprdrClientContext *clip, const CLIPRDR_FILE_CONTENTS_RESPONSE *response) {
    SDRDPClient *client = owner(clip->rdpcontext);
    if (response->cbRequested > 1024 * 1024 || (response->cbRequested && !response->requestedData)) return ERROR_INVALID_DATA;
    if (client.fileReceived) client.fileReceived(response->streamId,
        [NSData dataWithBytes:response->requestedData length:response->cbRequested], (response->common.msgFlags & CB_RESPONSE_OK) != 0);
    return CHANNEL_RC_OK;
}
static UINT displayCaps(DispClientContext *display, UINT32 count, UINT32 a, UINT32 b) {
    SDRDPClient *client = (__bridge SDRDPClient *)display->custom;
    if (count == 0 || a == 0 || b == 0) return ERROR_INVALID_DATA;
    client->_maximumMonitors = MIN(count, 16);
    client->_maximumMonitorArea = MIN((uint64_t)a * b * MIN(count, 16), SDMaximumPixels);
    if (client.displayCapabilities) client.displayCapabilities(MIN(count, 16));
    return CHANNEL_RC_OK;
}
static void channelConnected(void *context, const ChannelConnectedEventArgs *event) {
    SDRDPClient *client = owner(context);
    if (!strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME)) {
        CliprdrClientContext *clip = event->pInterface; client->_clipboard = clip;
        clip->ServerCapabilities = clipCapabilities; clip->MonitorReady = clipReady;
        clip->ServerFormatList = clipFormatList; clip->ServerFormatListResponse = clipListResponse;
        clip->ServerFormatDataRequest = clipDataRequest; clip->ServerFormatDataResponse = clipDataResponse;
        clip->ServerFileContentsRequest = clipFileRequest; clip->ServerFileContentsResponse = clipFileResponse;
    } else if (!strcmp(event->name, DISP_DVC_CHANNEL_NAME)) {
        client->_display = event->pInterface; client->_display->custom = (__bridge void *)client;
        client->_display->DisplayControlCaps = displayCaps;
    } else if (!strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME)) {
        gdi_graphics_pipeline_init(((rdpContext *)context)->gdi, event->pInterface);
    }
}
static void channelDisconnected(void *context, const ChannelDisconnectedEventArgs *event) {
    SDRDPClient *client = owner(context);
    if (!strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME)) client->_clipboard = NULL;
    if (!strcmp(event->name, DISP_DVC_CHANNEL_NAME)) client->_display = NULL;
    if (!strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME)) gdi_graphics_pipeline_uninit(((rdpContext *)context)->gdi, event->pInterface);
}
static BOOL preConnect(freerdp *instance) {
    return PubSub_SubscribeChannelConnected(instance->context->pubSub, channelConnected) >= 0 &&
        PubSub_SubscribeChannelDisconnected(instance->context->pubSub, channelDisconnected) >= 0 &&
        freerdp_client_load_addins(instance->context->channels, instance->context->settings);
}
static BOOL postConnect(freerdp *instance) {
    rdpContext *context = instance->context;
    if (!validSize(freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth),
                   freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight))) return FALSE;
    SDRDPClient *client = owner(context);
    pthread_mutex_lock(&client->_frameLock);
    BOOL result = gdi_init(instance, PIXEL_FORMAT_BGRA32);
    client->_dirty = YES; client->_fullFrame = YES;
    pthread_mutex_unlock(&client->_frameLock);
    if (!result) return FALSE;
    context->update->BeginPaint = beginPaint; context->update->EndPaint = endPaint;
    context->update->DesktopResize = desktopResize;
    return TRUE;
}

@implementation SDRDPClient
- (instancetype)initWithConfiguration:(NSDictionary *)configuration password:(NSString *)password {
    if ((self = [super init])) {
        _configuration = [configuration copy]; _password = [password copy];
        _commands = [NSMutableArray array]; _commandLock = [[NSLock alloc] init];
        _lifetimeLock = [[NSLock alloc] init];
        atomic_init(&_cancelled, false); atomic_init(&_connected, false);
        atomic_init(&_openFiles, 0);
        pthread_mutexattr_t attributes; pthread_mutexattr_init(&attributes);
        pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&_frameLock, &attributes); pthread_mutexattr_destroy(&attributes);
    }
    return self;
}
- (void)dealloc { pthread_mutex_destroy(&_frameLock); }
- (BOOL)enqueue:(void (^)(void))block {
    if (atomic_load(&_cancelled) || !atomic_load(&_connected)) return NO;
    [_commandLock lock];
    BOOL allowed = _commands.count < 4096;
    if (allowed) [_commands addObject:[block copy]];
    [_commandLock unlock];
    if (!allowed) [self cancel]; // Never silently drop an input while leaving a stuck key/session.
    return allowed;
}
- (void)run {
    @autoreleasepool {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            WLog_SetLogLevel(WLog_GetRoot(), WLOG_OFF);
            freerdp_register_addin_provider(SDRDPAddinProvider, 0);
        });
        [_lifetimeLock lock];
        _instance = freerdp_new();
        if (!_instance) { [_lifetimeLock unlock]; if (self.stateChanged) self.stateChanged(3, 0); return; }
        _instance->ContextSize = sizeof(SDContext);
        if (!freerdp_context_new(_instance)) { freerdp_free(_instance); _instance = NULL; [_lifetimeLock unlock]; if (self.stateChanged) self.stateChanged(3, 0); return; }
        ((SDContext *)_instance->context)->owner = (__bridge void *)self;
        [_lifetimeLock unlock];
        rdpSettings *settings = _instance->context->settings;
        BOOL ok = YES;
#define SD_BOOL(key, value) ok = freerdp_settings_set_bool(settings, FreeRDP_##key, (value)) && ok
#define SD_UINT(key, value) ok = freerdp_settings_set_uint32(settings, FreeRDP_##key, (value)) && ok
#define SD_STRING(key, value) ok = freerdp_settings_set_string(settings, FreeRDP_##key, [(value) UTF8String]) && ok
        SD_STRING(ServerHostname, _configuration[@"host"]); SD_UINT(ServerPort, [_configuration[@"port"] unsignedIntValue]);
        SD_STRING(Username, _configuration[@"username"]); SD_STRING(Domain, _configuration[@"domain"]); SD_STRING(Password, _password);
        SD_UINT(DesktopWidth, [_configuration[@"width"] unsignedIntValue]); SD_UINT(DesktopHeight, [_configuration[@"height"] unsignedIntValue]);
        SD_UINT(ColorDepth, [_configuration[@"colorDepth"] unsignedIntValue]);
        NSArray *monitors = _configuration[@"monitors"];
        if (monitors.count > 1 && monitors.count <= 16) {
            rdpMonitor layout[16] = {0};
            int left = 0, top = 0, right = 0, bottom = 0;
            for (NSUInteger index = 0; index < monitors.count; index++) {
                NSDictionary *m = monitors[index];
                layout[index].x = [m[@"x"] intValue]; layout[index].y = [m[@"y"] intValue];
                layout[index].width = [m[@"width"] intValue]; layout[index].height = [m[@"height"] intValue];
                layout[index].is_primary = [m[@"primary"] boolValue];
                left = MIN(left, layout[index].x); top = MIN(top, layout[index].y);
                right = MAX(right, layout[index].x + layout[index].width); bottom = MAX(bottom, layout[index].y + layout[index].height);
            }
            ok = validSize(right - left, bottom - top) && freerdp_settings_set_monitor_def_array_sorted(settings, layout, monitors.count) && ok;
            SD_BOOL(UseMultimon, TRUE); SD_BOOL(ForceMultimon, TRUE);
            SD_UINT(DesktopWidth, right - left); SD_UINT(DesktopHeight, bottom - top);
        }
        SD_BOOL(NlaSecurity, TRUE); SD_BOOL(TlsSecurity, FALSE); SD_BOOL(RdpSecurity, FALSE); SD_BOOL(ExtSecurity, FALSE);
        SD_BOOL(NegotiateSecurityLayer, TRUE); SD_BOOL(Authentication, TRUE); SD_BOOL(ExternalCertificateManagement, TRUE);
        SD_BOOL(IgnoreCertificate, FALSE); SD_BOOL(AutoAcceptCertificate, FALSE); SD_BOOL(AutoDenyCertificate, FALSE);
        ok = freerdp_settings_set_uint16(settings, FreeRDP_TLSMinVersion, 0x0303) && ok;
        SD_UINT(TlsSecLevel, 2); SD_UINT(TcpConnectTimeout, 15000);
        SD_BOOL(AutoReconnectionEnabled, FALSE); SD_BOOL(RedirectClipboard, [_configuration[@"textClipboard"] boolValue] || [_configuration[@"fileClipboard"] boolValue]);
        SD_BOOL(RedirectDrives, [_configuration[@"shares"] count] > 0); SD_BOOL(RedirectPrinters, FALSE); SD_BOOL(RedirectSmartCards, FALSE);
        for (NSDictionary *share in _configuration[@"shares"]) {
            RDPDR_DRIVE *drive = calloc(1, sizeof(RDPDR_DRIVE));
            if (!drive) { ok = NO; break; }
            drive->device.Type = RDPDR_DTYP_FILESYSTEM;
            drive->device.Name = strdup([share[@"name"] UTF8String]);
            drive->Path = strdup([share[@"url"] fileSystemRepresentation]);
            if (!drive->device.Name || !drive->Path || !freerdp_device_collection_add(settings, &drive->device)) {
                free(drive->device.Name); free(drive->Path); free(drive); ok = NO; break;
            }
        }
        SD_BOOL(AudioCapture, FALSE); SD_BOOL(AudioPlayback, [_configuration[@"audio"] isEqual:@"local"]);
        SD_BOOL(RemoteConsoleAudio, [_configuration[@"audio"] isEqual:@"remote"]);
        SD_BOOL(SupportDisplayControl, TRUE); SD_BOOL(DynamicResolutionUpdate, TRUE);
        SD_BOOL(BitmapCacheEnabled, [_configuration[@"bitmapCache"] boolValue]);
        SD_BOOL(BitmapCachePersistEnabled, FALSE);
        SD_BOOL(DisableWallpaper, [_configuration[@"disableWallpaper"] boolValue]);
        SD_BOOL(DisableFullWindowDrag, [_configuration[@"disableWindowDrag"] boolValue]);
        SD_BOOL(DisableMenuAnims, [_configuration[@"disableMenuAnimations"] boolValue]);
        SD_BOOL(DisableThemes, [_configuration[@"disableThemes"] boolValue]);
        SD_BOOL(SupportGraphicsPipeline, FALSE); SD_BOOL(GfxH264, FALSE); SD_BOOL(NSCodec, TRUE);
        _instance->PreConnect = preConnect; _instance->PostConnect = postConnect;
        _instance->VerifyX509Certificate = verifyCertificate; _instance->Redirect = noRedirect;
        _instance->AuthenticateEx = noAuthentication;
        BOOL connected = ok && !atomic_load(&_cancelled) && freerdp_connect(_instance);
        atomic_store(&_connected, connected);
        if (connected && self.stateChanged) self.stateChanged(1, 0);
        while (connected && !atomic_load(&_cancelled) && !freerdp_shall_disconnect_context(_instance->context)) {
            @autoreleasepool {
                [_commandLock lock]; NSArray *commands = [_commands copy]; [_commands removeAllObjects]; [_commandLock unlock];
                for (void (^command)(void) in commands) { if (!atomic_load(&_cancelled)) command(); }
                HANDLE handles[MAXIMUM_WAIT_OBJECTS];
                DWORD count = freerdp_get_event_handles(_instance->context, handles, MAXIMUM_WAIT_OBJECTS);
                if (!count || WaitForMultipleObjects(count, handles, FALSE, 20) == WAIT_FAILED ||
                    !freerdp_check_event_handles(_instance->context)) break;
            }
        }
        atomic_store(&_connected, false);
        // A malformed update may abort between BeginPaint/EndPaint. Release on its owning worker.
        if (_paintLocked) { _paintLocked = NO; pthread_mutex_unlock(&_frameLock); }
        uint32_t error = freerdp_get_last_error(_instance->context);
        freerdp_disconnect(_instance);
        [_lifetimeLock lock];
        pthread_mutex_lock(&_frameLock);
        if (_instance->context->gdi) gdi_free(_instance);
        freerdp_context_free(_instance); freerdp_free(_instance); _instance = NULL;
        pthread_mutex_unlock(&_frameLock);
        [_lifetimeLock unlock];
        _password = nil;
        [_commandLock lock]; [_commands removeAllObjects]; [_commandLock unlock];
        if (self.stateChanged) self.stateChanged(atomic_load(&_cancelled) ? 2 : 3, error);
    }
}
- (void)cancel {
    atomic_store(&_cancelled, true);
    [_lifetimeLock lock];
    if (_instance && _instance->context) freerdp_abort_connect_context(_instance->context);
    [_lifetimeLock unlock];
}
- (BOOL)hasActiveFileTransfers { return atomic_load(&_openFiles) > 0; }
- (NSDictionary *)copyFrame {
    if (!atomic_load(&_connected)) return nil;
    pthread_mutex_lock(&_frameLock);
    rdpGdi *gdi = _instance ? _instance->context->gdi : NULL;
    NSDictionary *result = nil;
    if (_dirty && gdi && gdi->primary_buffer && validSize(gdi->width, gdi->height) && gdi->stride >= gdi->width * 4) {
        NSMutableData *data = [NSMutableData dataWithLength:(size_t)gdi->width * gdi->height * 4];
        for (UINT32 row = 0; row < gdi->height; row++)
            memcpy((BYTE *)data.mutableBytes + (size_t)row * gdi->width * 4, gdi->primary_buffer + (size_t)row * gdi->stride, (size_t)gdi->width * 4);
        CGRect region = _fullFrame ? CGRectMake(0, 0, gdi->width, gdi->height) : _dirtyRect;
        result = @{ @"width": @(gdi->width), @"height": @(gdi->height), @"data": data, @"sequence": @(++_frameSequence),
                    @"colorDepth": @(freerdp_settings_get_uint32(_instance->context->settings, FreeRDP_ColorDepth)),
                    @"x": @(region.origin.x), @"y": @(region.origin.y), @"w": @(region.size.width), @"h": @(region.size.height) };
        _dirty = NO; _fullFrame = NO; _dirtyRect = CGRectZero;
    }
    pthread_mutex_unlock(&_frameLock);
    return result;
}
- (BOOL)sendKey:(uint16_t)code down:(BOOL)down {
    return [self enqueue:^{ freerdp_input_send_keyboard_event_ex(self->_instance->context->input, down, FALSE, code); }];
}
- (BOOL)sendUnicode:(uint16_t)character down:(BOOL)down {
    return [self enqueue:^{ freerdp_input_send_unicode_keyboard_event(self->_instance->context->input, down ? 0 : KBD_FLAGS_RELEASE, character); }];
}
- (BOOL)sendPointer:(uint16_t)flags x:(uint16_t)x y:(uint16_t)y {
    return [self enqueue:^{ freerdp_input_send_mouse_event(self->_instance->context->input, flags, x, y); }];
}
- (BOOL)setMonitors:(NSArray<NSDictionary *> *)monitors {
    if (!monitors.count || monitors.count > 16) return NO;
    return [self enqueue:^{
        if (!self->_display) return;
        if (monitors.count > self->_maximumMonitors) { if (self.displayResizeRejected) self.displayResizeRejected(); return; }
        DISPLAY_CONTROL_MONITOR_LAYOUT layout[16] = {0};
        uint64_t area = 0;
        for (NSUInteger index = 0; index < monitors.count; index++) {
            NSDictionary *value = monitors[index];
            layout[index].Flags = [value[@"primary"] boolValue] ? DISPLAY_CONTROL_MONITOR_PRIMARY : 0;
            layout[index].Left = [value[@"x"] intValue]; layout[index].Top = [value[@"y"] intValue];
            layout[index].Width = [value[@"width"] unsignedIntValue]; layout[index].Height = [value[@"height"] unsignedIntValue];
            layout[index].DesktopScaleFactor = 100; layout[index].DeviceScaleFactor = 100;
            area += (uint64_t)layout[index].Width * layout[index].Height;
        }
        if (area > self->_maximumMonitorArea) { if (self.displayResizeRejected) self.displayResizeRejected(); return; }
        if (self->_display->SendMonitorLayout(self->_display, (UINT32)monitors.count, layout) != CHANNEL_RC_OK && self.displayResizeRejected)
            self.displayResizeRejected();
    }];
}
- (BOOL)announceClipboard:(BOOL)text files:(BOOL)files {
    return [self enqueue:^{
        if (!self->_clipboard) return;
        self->_announcedText = text && [self->_configuration[@"textClipboard"] boolValue];
        self->_announcedFiles = files && [self->_configuration[@"fileClipboard"] boolValue] &&
            (self->_serverClipboardFlags & CB_STREAM_FILECLIP_ENABLED);
        CLIPRDR_FORMAT formats[2] = {0}; UINT32 count = 0;
        if (self->_announcedText) formats[count++].formatId = CF_UNICODETEXT;
        if (self->_announcedFiles) { formats[count].formatId = SDFileFormat; formats[count++].formatName = "FileGroupDescriptorW"; }
        CLIPRDR_FORMAT_LIST list = {0}; list.numFormats = count; list.formats = formats;
        self->_clipboard->ClientFormatList(self->_clipboard, &list);
    }];
}
- (BOOL)requestClipboard:(uint32_t)format {
    return [self enqueue:^{
        if (!self->_clipboard) return;
        if (format != CF_UNICODETEXT && format != self->_remoteFileFormat) return;
        if (self->_requestedFormat) { self->_pendingFormat = format; return; }
        self->_requestedFormat = format;
        self->_requestedClipboardRevision = self->_clipboardRevision;
        CLIPRDR_FORMAT_DATA_REQUEST request = {0}; request.requestedFormatId = format;
        self->_clipboard->ClientFormatDataRequest(self->_clipboard, &request);
    }];
}
- (BOOL)requestFile:(uint32_t)index offset:(uint64_t)offset count:(uint32_t)count stream:(uint32_t)stream {
    if (!count || count > 1024 * 1024) return NO;
    return [self enqueue:^{
        if (!self->_clipboard) return;
        CLIPRDR_FILE_CONTENTS_REQUEST request = {0}; request.streamId = stream; request.listIndex = index;
        request.dwFlags = FILECONTENTS_RANGE; request.nPositionLow = (UINT32)offset;
        request.nPositionHigh = (UINT32)(offset >> 32); request.cbRequested = count;
        self->_clipboard->ClientFileContentsRequest(self->_clipboard, &request);
    }];
}
@end

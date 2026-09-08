#import <Foundation/Foundation.h>
#import "SDRDPDirectory.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL SDRDPCertificateIsSelfSigned(NSData *pem);
/// All callbacks run on the connection worker. UI must dispatch without blocking that worker.
@interface SDRDPClient : NSObject
@property(nonatomic, copy, nullable) BOOL (^verifyCertificate)(NSData *chain, NSString *host, NSInteger port);
@property(nonatomic, copy, nullable) void (^stateChanged)(NSInteger state, uint32_t error);
@property(nonatomic, copy, nullable) void (^clipboardReceived)(NSData *data, uint32_t format);
@property(nonatomic, copy, nullable) void (^clipboardFormats)(uint32_t fileFormat);
@property(nonatomic, copy, nullable) NSData *_Nullable (^clipboardRequested)(uint32_t format);
@property(nonatomic, copy, nullable) NSData *_Nullable (^fileRequested)(uint32_t index, uint64_t offset, uint32_t count, BOOL sizeOnly);
@property(nonatomic, copy, nullable) void (^fileReceived)(uint32_t stream, NSData *data, BOOL success);
@property(nonatomic, copy, nullable) void (^displayCapabilities)(uint32_t maximumMonitors);
@property(nonatomic, copy, nullable) void (^displayResizeRejected)(void);
- (instancetype)initWithConfiguration:(NSDictionary *)configuration password:(NSString *)password;
/// Blocking; run once on a dedicated serial worker. Credentials are released when run ends.
- (void)run;
- (void)cancel;
- (BOOL)hasActiveFileTransfers;
/// Called from a rendering worker. The returned buffer is immutable and bounds checked.
- (nullable NSDictionary *)copyFrame;
- (BOOL)sendKey:(uint16_t)scancode down:(BOOL)down;
- (BOOL)sendUnicode:(uint16_t)character down:(BOOL)down;
- (BOOL)sendPointer:(uint16_t)flags x:(uint16_t)x y:(uint16_t)y;
- (BOOL)setMonitors:(NSArray<NSDictionary *> *)monitors;
- (BOOL)announceClipboard:(BOOL)text files:(BOOL)files;
- (BOOL)requestClipboard:(uint32_t)format;
- (BOOL)requestFile:(uint32_t)index offset:(uint64_t)offset count:(uint32_t)count stream:(uint32_t)stream;
@end
NS_ASSUME_NONNULL_END

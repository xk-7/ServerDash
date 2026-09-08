#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Descriptor-relative file access. No operation follows symlinks or silently overwrites a file.
@interface SDRDPDirectory : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url readOnly:(BOOL)readOnly;
- (int)openPath:(NSString *)path create:(BOOL)create directory:(BOOL)directory write:(BOOL)write;
- (BOOL)renamePath:(NSString *)source to:(NSString *)destination;
- (BOOL)removePath:(NSString *)path directory:(BOOL)directory;
@property(nonatomic, readonly) int rootDescriptor;
@property(nonatomic, readonly) BOOL readOnly;
@end
NS_ASSUME_NONNULL_END

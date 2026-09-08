#import "SDRDPDirectory.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

@implementation SDRDPDirectory {
    int _rootDescriptor;
    BOOL _readOnly;
}
- (instancetype)initWithURL:(NSURL *)url readOnly:(BOOL)readOnly {
    if ((self = [super init])) {
        _readOnly = readOnly;
        _rootDescriptor = open(url.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (_rootDescriptor < 0) return nil;
    }
    return self;
}
- (void)dealloc { if (_rootDescriptor >= 0) close(_rootDescriptor); }
- (int)rootDescriptor { return _rootDescriptor; }
- (BOOL)readOnly { return _readOnly; }
- (NSArray<NSString *> *)components:(NSString *)path {
    NSMutableCharacterSet *forbidden = [NSCharacterSet.controlCharacterSet mutableCopy];
    [forbidden removeCharactersInString:@"\u200c\u200d"];
    if (path.length > 4096 || [path rangeOfCharacterFromSet:forbidden].location != NSNotFound ||
        [path containsString:@":"] || [path hasPrefix:@"\\\\"] || [path hasPrefix:@"//"]) return nil;
    NSString *normal = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if ([normal hasPrefix:@"/"]) normal = [normal substringFromIndex:1];
    if (normal.length == 0) return @[];
    NSArray *parts = [normal componentsSeparatedByString:@"/"];
    if (parts.count > 128) return nil;
    for (NSString *part in parts) if (!part.length || [part isEqual:@"."] || [part isEqual:@".."] || [part lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255) return nil;
    return parts;
}
- (int)parentFor:(NSArray<NSString *> *)parts {
    int parent = dup(_rootDescriptor);
    for (NSUInteger index = 0; parent >= 0 && index + 1 < parts.count; index++) {
        int next = openat(parent, parts[index].fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(parent); parent = next;
    }
    return parent;
}
- (int)openPath:(NSString *)path create:(BOOL)create directory:(BOOL)directory write:(BOOL)write {
    if (_readOnly && (create || write)) return -1;
    NSArray<NSString *> *parts = [self components:path];
    if (!parts) return -1;
    if (parts.count == 0) return create || write ? -1 : dup(_rootDescriptor);
    int parent = [self parentFor:parts];
    if (parent < 0) return -1;
    const char *name = parts.lastObject.fileSystemRepresentation;
    if (directory && create && mkdirat(parent, name, 0700) != 0) { close(parent); return -1; }
    int flags = O_CLOEXEC | O_NOFOLLOW | (directory ? O_RDONLY | O_DIRECTORY : (write ? O_RDWR : O_RDONLY));
    if (create && !directory) flags |= O_CREAT | O_EXCL;
    // Existing files are never opened writable without a separate, explicit overwrite workflow.
    if (write && !create) { close(parent); return -1; }
    int result = openat(parent, name, flags, 0600);
    close(parent);
    if (result >= 0) {
        struct stat info;
        if (fstat(result, &info) != 0 || (!S_ISREG(info.st_mode) && !S_ISDIR(info.st_mode)) ||
            (S_ISREG(info.st_mode) && info.st_nlink != 1)) { close(result); return -1; }
    }
    return result;
}
- (BOOL)renamePath:(NSString *)source to:(NSString *)destination {
    if (_readOnly) return NO;
    NSArray *src = [self components:source], *dst = [self components:destination];
    if (!src.count || !dst.count) return NO;
    int first = [self parentFor:src], second = [self parentFor:dst];
    BOOL success = NO;
    if (first >= 0 && second >= 0) {
        struct stat info;
        if (fstatat(first, [src.lastObject fileSystemRepresentation], &info, AT_SYMLINK_NOFOLLOW) == 0 && !S_ISLNK(info.st_mode))
            success = renameatx_np(first, [src.lastObject fileSystemRepresentation], second, [dst.lastObject fileSystemRepresentation], RENAME_EXCL) == 0;
    }
    if (first >= 0) close(first); if (second >= 0) close(second);
    return success;
}
- (BOOL)removePath:(NSString *)path directory:(BOOL)directory {
    if (_readOnly) return NO;
    NSArray *parts = [self components:path];
    if (!parts.count) return NO;
    int parent = [self parentFor:parts];
    if (parent < 0) return NO;
    struct stat info;
    BOOL success = fstatat(parent, [parts.lastObject fileSystemRepresentation], &info, AT_SYMLINK_NOFOLLOW) == 0 && !S_ISLNK(info.st_mode) &&
        unlinkat(parent, [parts.lastObject fileSystemRepresentation], directory ? AT_REMOVEDIR : 0) == 0;
    close(parent); return success;
}
@end

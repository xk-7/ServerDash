#import "SDRDPDirectory.h"
#define REFIID WINPR_REFIID
#include <freerdp/freerdp.h>
#include <freerdp/addin.h>
#include <freerdp/client/channels.h>
#include <freerdp/channels/rdpdr.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <dirent.h>
#include <fnmatch.h>
#include <unistd.h>
#include <fcntl.h>

extern NSDictionary *SDRDPShareForContext(rdpContext *context, const char *name);
extern void SDRDPFileOpened(rdpContext *context);
extern void SDRDPFileClosed(rdpContext *context);
@interface SDRDPDriveFile : NSObject
@property int fd;
@property DIR *directory;
@property BOOL writable;
@property BOOL deletePending;
@property rdpContext *context;
@property(copy) NSString *path;
@property(copy) NSString *pattern;
@end
@implementation SDRDPDriveFile
- (instancetype)init { if ((self = [super init])) _fd = -1; return self; }
- (void)dealloc { if (_directory) closedir(_directory); if (_fd >= 0) close(_fd); if (_context) SDRDPFileClosed(_context); }
@end
typedef struct {
    DEVICE device;
    void *directory;
    void *files;
    rdpContext *context;
} SDDrive;
static uint64_t windowsTime(struct timespec t) { return ((uint64_t)t.tv_sec + 11644473600ull) * 10000000ull + t.tv_nsec / 100; }
static UINT32 attributes(struct stat info) { return S_ISDIR(info.st_mode) ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL; }
static NSString *readPath(wStream *input, UINT32 length) {
    if (length > 8192 || length % 2 || Stream_GetRemainingLength(input) < length) return nil;
    NSString *path = [[NSString alloc] initWithBytes:Stream_ConstPointer(input) length:length encoding:NSUTF16LittleEndianStringEncoding];
    Stream_Seek(input, length);
    if ([path hasSuffix:@"\0"]) path = [path substringToIndex:path.length - 1];
    return path;
}
static UINT complete(IRP *irp, NTSTATUS status) { irp->IoStatus = status; return irp->Complete(irp); }
static void basicInfo(wStream *output, struct stat info) {
    Stream_Write_UINT64(output, windowsTime(info.st_birthtimespec));
    Stream_Write_UINT64(output, windowsTime(info.st_atimespec));
    Stream_Write_UINT64(output, windowsTime(info.st_mtimespec));
    Stream_Write_UINT64(output, windowsTime(info.st_ctimespec));
}
static UINT driveRequest(DEVICE *device, IRP *irp) {
    @autoreleasepool {
        SDDrive *drive = (SDDrive *)device;
        SDRDPDirectory *root = (__bridge SDRDPDirectory *)drive->directory;
        NSMutableDictionary *files = (__bridge NSMutableDictionary *)drive->files;
        SDRDPDriveFile *file = files[@(irp->FileId)];
        wStream *input = irp->input, *output = irp->output;
        if (!Stream_EnsureRemainingCapacity(output, 1024 * 1024 + 1024)) return complete(irp, STATUS_NO_MEMORY);
        switch (irp->MajorFunction) {
            case IRP_MJ_CREATE: {
                if (Stream_GetRemainingLength(input) < 32 || files.count >= 1024) return complete(irp, STATUS_INVALID_PARAMETER);
                UINT32 access = Stream_Get_UINT32(input); Stream_Seek(input, 8);
                Stream_Seek(input, 8); UINT32 disposition = Stream_Get_UINT32(input), options = Stream_Get_UINT32(input), length = Stream_Get_UINT32(input);
                NSString *path = readPath(input, length);
                if (!path) return complete(irp, STATUS_OBJECT_PATH_INVALID);
                BOOL write = (access & (GENERIC_WRITE | FILE_WRITE_DATA | FILE_APPEND_DATA)) != 0;
                BOOL directory = (options & FILE_DIRECTORY_FILE) != 0;
                BOOL create = disposition == FILE_CREATE || disposition == FILE_OPEN_IF;
                if (disposition != FILE_OPEN && disposition != FILE_OPEN_IF && disposition != FILE_CREATE) return complete(irp, STATUS_ACCESS_DENIED);
                int fd = -1;
                if (disposition == FILE_OPEN_IF) fd = [root openPath:path create:NO directory:directory write:write];
                BOOL created = fd < 0 && create;
                if (fd < 0) fd = [root openPath:path create:create directory:directory write:write];
                if (fd < 0) { Stream_Write_UINT32(output, 0); Stream_Write_UINT8(output, 0); return complete(irp, STATUS_ACCESS_DENIED); }
                SDRDPDriveFile *opened = [[SDRDPDriveFile alloc] init]; opened.fd = fd; opened.path = path; opened.writable = write && !root.readOnly;
                struct stat metadata = {0};
                if (!fstat(fd, &metadata) && S_ISREG(metadata.st_mode)) { opened.context = drive->context; SDRDPFileOpened(drive->context); }
                opened.deletePending = (options & FILE_DELETE_ON_CLOSE) != 0 && !root.readOnly;
                UINT32 id = irp->devman->id_sequence++; files[@(id)] = opened;
                Stream_Write_UINT32(output, id); Stream_Write_UINT8(output, created ? FILE_CREATED : FILE_OPENED);
                return complete(irp, STATUS_SUCCESS);
            }
            case IRP_MJ_CLOSE: {
                if (file.deletePending) { struct stat info; if (!fstat(file.fd, &info)) [root removePath:file.path directory:S_ISDIR(info.st_mode)]; }
                [files removeObjectForKey:@(irp->FileId)]; Stream_Zero(output, 5); return complete(irp, STATUS_SUCCESS);
            }
            case IRP_MJ_READ:
            case IRP_MJ_WRITE: {
                if (!file || Stream_GetRemainingLength(input) < 12) return complete(irp, STATUS_INVALID_HANDLE);
                UINT32 length = Stream_Get_UINT32(input); UINT64 offset = Stream_Get_UINT64(input);
                if (length > 1024 * 1024 || offset > INT64_MAX - length) return complete(irp, STATUS_INVALID_PARAMETER);
                ssize_t result;
                if (irp->MajorFunction == IRP_MJ_WRITE) {
                    if (!file.writable || root.readOnly || Stream_GetRemainingLength(input) < 20ull + length) return complete(irp, STATUS_ACCESS_DENIED);
                    Stream_Seek(input, 20); result = pwrite(file.fd, Stream_ConstPointer(input), length, (off_t)offset);
                    Stream_Write_UINT32(output, result < 0 ? 0 : (UINT32)result); Stream_Write_UINT8(output, 0);
                } else {
                    size_t start = Stream_GetPosition(output); Stream_Seek(output, 4);
                    result = pread(file.fd, Stream_Pointer(output), length, (off_t)offset);
                    Stream_SetPosition(output, start); Stream_Write_UINT32(output, result < 0 ? 0 : (UINT32)result);
                    if (result > 0) Stream_Seek(output, result);
                }
                return complete(irp, result < 0 ? STATUS_UNSUCCESSFUL : STATUS_SUCCESS);
            }
            case IRP_MJ_QUERY_INFORMATION: {
                if (!file || Stream_GetRemainingLength(input) < 4) return complete(irp, STATUS_INVALID_HANDLE);
                struct stat info; if (fstat(file.fd, &info)) return complete(irp, STATUS_UNSUCCESSFUL);
                UINT32 type = Stream_Get_UINT32(input);
                if (type == FileBasicInformation) { Stream_Write_UINT32(output, 36); basicInfo(output, info); Stream_Write_UINT32(output, attributes(info)); }
                else if (type == FileStandardInformation) {
                    Stream_Write_UINT32(output, 22); Stream_Write_UINT64(output, info.st_blocks * 512); Stream_Write_UINT64(output, info.st_size);
                    Stream_Write_UINT32(output, info.st_nlink); Stream_Write_UINT8(output, file.deletePending); Stream_Write_UINT8(output, S_ISDIR(info.st_mode));
                } else if (type == FileAttributeTagInformation) { Stream_Write_UINT32(output, 8); Stream_Write_UINT32(output, attributes(info)); Stream_Write_UINT32(output, 0); }
                else { Stream_Write_UINT32(output, 0); return complete(irp, STATUS_NOT_SUPPORTED); }
                return complete(irp, STATUS_SUCCESS);
            }
            case IRP_MJ_SET_INFORMATION: {
                if (!file || root.readOnly || Stream_GetRemainingLength(input) < 32) return complete(irp, STATUS_ACCESS_DENIED);
                UINT32 type = Stream_Get_UINT32(input), length = Stream_Get_UINT32(input); Stream_Seek(input, 24);
                if (length > Stream_GetRemainingLength(input)) return complete(irp, STATUS_INVALID_PARAMETER);
                BOOL success = NO;
                if (type == FileDispositionInformation && length >= 1) { file.deletePending = Stream_Get_UINT8(input) != 0; success = YES; }
                else if ((type == FileEndOfFileInformation || type == FileAllocationInformation) && length >= 8 && file.writable) {
                    UINT64 size = Stream_Get_UINT64(input); success = size <= INT64_MAX && ftruncate(file.fd, (off_t)size) == 0;
                } else if (type == FileRenameInformation && length >= 6) {
                    BOOL replace = Stream_Get_UINT8(input); Stream_Seek(input, 1); UINT32 bytes = Stream_Get_UINT32(input);
                    NSString *destination = readPath(input, bytes);
                    if (destination && !replace) { success = [root renamePath:file.path to:destination]; if (success) file.path = destination; }
                } else if (type == FileBasicInformation && length >= 36) {
                    Stream_Write_UINT32(output, 0); return complete(irp, STATUS_NOT_SUPPORTED);
                }
                Stream_Write_UINT32(output, length); return complete(irp, success ? STATUS_SUCCESS : STATUS_ACCESS_DENIED);
            }
            case IRP_MJ_DIRECTORY_CONTROL: {
                if (!file || irp->MinorFunction != IRP_MN_QUERY_DIRECTORY || Stream_GetRemainingLength(input) < 32) return complete(irp, STATUS_NOT_SUPPORTED);
                UINT32 type = Stream_Get_UINT32(input); BOOL initial = Stream_Get_UINT8(input); UINT32 length = Stream_Get_UINT32(input); Stream_Seek(input, 23);
                NSString *path = readPath(input, length);
                if (!path) return complete(irp, STATUS_OBJECT_PATH_INVALID);
                if (initial || !file.directory) {
                    if (file.directory) closedir(file.directory);
                    file.directory = fdopendir(dup(file.fd)); file.pattern = [[path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent];
                }
                if (!file.directory) return complete(irp, STATUS_NOT_A_DIRECTORY);
                struct dirent *entry; struct stat info = {0}; NSString *name = nil;
                while ((entry = readdir(file.directory))) {
                    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
                    if (file.pattern.length && ![file.pattern isEqual:@"*.*"] && fnmatch(file.pattern.UTF8String, entry->d_name, 0)) continue;
                    if (fstatat(file.fd, entry->d_name, &info, AT_SYMLINK_NOFOLLOW) || S_ISLNK(info.st_mode)) continue;
                    name = @(entry->d_name); break;
                }
                if (!name) { Stream_Write_UINT32(output, 0); Stream_Write_UINT8(output, 0); return complete(irp, STATUS_NO_MORE_FILES); }
                NSData *encoded = [name dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
                UINT32 header = type == FileBothDirectoryInformation ? 93 : type == FileFullDirectoryInformation ? 68 : type == FileDirectoryInformation ? 64 : type == FileNamesInformation ? 12 : 0;
                if (!header) return complete(irp, STATUS_NOT_SUPPORTED);
                Stream_Write_UINT32(output, header + (UINT32)encoded.length); Stream_Write_UINT32(output, 0); Stream_Write_UINT32(output, 0);
                if (type != FileNamesInformation) { basicInfo(output, info); Stream_Write_UINT64(output, info.st_size); Stream_Write_UINT64(output, info.st_blocks * 512); Stream_Write_UINT32(output, attributes(info)); }
                Stream_Write_UINT32(output, (UINT32)encoded.length);
                if (type == FileFullDirectoryInformation || type == FileBothDirectoryInformation) Stream_Write_UINT32(output, 0);
                if (type == FileBothDirectoryInformation) { Stream_Write_UINT8(output, 0); Stream_Zero(output, 24); }
                Stream_Write(output, encoded.bytes, encoded.length); return complete(irp, STATUS_SUCCESS);
            }
            case IRP_MJ_QUERY_VOLUME_INFORMATION: {
                if (Stream_GetRemainingLength(input) < 4) return complete(irp, STATUS_INVALID_PARAMETER);
                UINT32 type = Stream_Get_UINT32(input); struct statfs info = {0}; fstatfs(root.rootDescriptor, &info);
                if (type == FileFsSizeInformation || type == FileFsFullSizeInformation) {
                    Stream_Write_UINT32(output, type == FileFsSizeInformation ? 24 : 32);
                    Stream_Write_UINT64(output, info.f_blocks); Stream_Write_UINT64(output, info.f_bavail);
                    if (type == FileFsFullSizeInformation) Stream_Write_UINT64(output, info.f_bfree);
                    Stream_Write_UINT32(output, 1); Stream_Write_UINT32(output, info.f_bsize);
                } else if (type == FileFsAttributeInformation) {
                    NSData *label = [@"ServerDash" dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
                    Stream_Write_UINT32(output, 12 + (UINT32)label.length); Stream_Write_UINT32(output, FILE_CASE_PRESERVED_NAMES | FILE_UNICODE_ON_DISK);
                    Stream_Write_UINT32(output, 255); Stream_Write_UINT32(output, (UINT32)label.length); Stream_Write(output, label.bytes, label.length);
                } else if (type == FileFsVolumeInformation) {
                    Stream_Write_UINT32(output, 17); Stream_Write_UINT64(output, 0); Stream_Write_UINT32(output, 1); Stream_Write_UINT32(output, 0); Stream_Write_UINT8(output, 0);
                } else if (type == FileFsDeviceInformation) { Stream_Write_UINT32(output, 8); Stream_Write_UINT32(output, FILE_DEVICE_DISK); Stream_Write_UINT32(output, 0); }
                else { Stream_Write_UINT32(output, 0); return complete(irp, STATUS_NOT_SUPPORTED); }
                return complete(irp, STATUS_SUCCESS);
            }
            default: Stream_Write_UINT32(output, 0); return complete(irp, STATUS_NOT_SUPPORTED);
        }
    }
}
static UINT driveFree(DEVICE *device) {
    SDDrive *drive = (SDDrive *)device;
    if (drive->files) CFBridgingRelease(drive->files);
    if (drive->directory) CFBridgingRelease(drive->directory);
    Stream_Free(drive->device.data, TRUE); free(drive); return CHANNEL_RC_OK;
}
static UINT VCAPITYPE driveEntry(PDEVICE_SERVICE_ENTRY_POINTS entry) {
    NSDictionary *config = SDRDPShareForContext(entry->rdpcontext, entry->device->Name);
    if (!config) return ERROR_ACCESS_DENIED;
    SDRDPDirectory *directory = [[SDRDPDirectory alloc] initWithURL:config[@"url"] readOnly:[config[@"readOnly"] boolValue]];
    if (!directory) return ERROR_ACCESS_DENIED;
    SDDrive *drive = calloc(1, sizeof(SDDrive)); if (!drive) return CHANNEL_RC_NO_MEMORY;
    drive->context = entry->rdpcontext;
    drive->directory = (void *)CFBridgingRetain(directory); drive->files = (void *)CFBridgingRetain([NSMutableDictionary dictionary]);
    drive->device.type = RDPDR_DTYP_FILESYSTEM; drive->device.IRPRequest = driveRequest; drive->device.Free = driveFree;
    const char *name = entry->device->Name; size_t count = strlen(name) + 1;
    drive->device.data = Stream_New(NULL, count); if (!drive->device.data) { driveFree(&drive->device); return CHANNEL_RC_NO_MEMORY; }
    Stream_Write(drive->device.data, name, count); drive->device.name = (char *)Stream_Buffer(drive->device.data);
    UINT result = entry->RegisterDevice(entry->devman, &drive->device);
    if (result) driveFree(&drive->device);
    return result;
}
PVIRTUALCHANNELENTRY SDRDPAddinProvider(LPCSTR name, LPCSTR subsystem, LPCSTR type, DWORD flags) {
    if (name && !strcmp(name, "drive")) return (PVIRTUALCHANNELENTRY)driveEntry;
    return freerdp_channels_load_static_addin_entry(name, subsystem, type, flags);
}

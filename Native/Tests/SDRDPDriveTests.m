// Standalone sanitizer harness. No network, real credentials, or user directories.
#import "../SDRDPDrive.m"

NSDictionary *SDRDPShareForContext(rdpContext *context, const char *name) { return nil; }
void SDRDPFileOpened(rdpContext *context) {}
void SDRDPFileClosed(rdpContext *context) {}
static UINT done(IRP *irp) { return CHANNEL_RC_OK; }
static NTSTATUS request(SDDrive *drive, DEVMAN *manager, UINT32 major, UINT32 minor, UINT32 file, NSData *data, NSMutableData **result) {
    IRP irp = {0}; irp.devman = manager; irp.device = &drive->device; irp.MajorFunction = major;
    irp.MinorFunction = minor; irp.FileId = file; irp.Complete = done;
    irp.input = Stream_New(NULL, MAX(1, data.length)); irp.output = Stream_New(NULL, 1024);
    assert(irp.input && irp.output);
    Stream_Write(irp.input, data.bytes, data.length); Stream_SealLength(irp.input); Stream_SetPosition(irp.input, 0);
    driveRequest(&drive->device, &irp);
    if (result) *result = [NSMutableData dataWithBytes:Stream_Buffer(irp.output) length:Stream_GetPosition(irp.output)];
    Stream_Free(irp.input, TRUE); Stream_Free(irp.output, TRUE);
    return irp.IoStatus;
}
static NSData *createRequest(NSString *path, BOOL write) {
    NSData *name = [path dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    wStream *s = Stream_New(NULL, name.length + 32);
    Stream_Write_UINT32(s, write ? GENERIC_WRITE : GENERIC_READ); Stream_Zero(s, 16);
    Stream_Write_UINT32(s, write ? FILE_CREATE : FILE_OPEN); Stream_Write_UINT32(s, FILE_NON_DIRECTORY_FILE);
    Stream_Write_UINT32(s, (UINT32)name.length); Stream_Write(s, name.bytes, name.length);
    NSData *data = [NSData dataWithBytes:Stream_Buffer(s) length:Stream_GetPosition(s)]; Stream_Free(s, TRUE); return data;
}
int main(void) {
    @autoreleasepool {
        NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[@"serverdash-rdp-asan-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        assert([NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL]);
        SDDrive *drive = calloc(1, sizeof(SDDrive)); DEVMAN manager = {0}; manager.id_sequence = 1;
        drive->directory = (void *)CFBridgingRetain([[SDRDPDirectory alloc] initWithURL:root readOnly:NO]);
        drive->files = (void *)CFBridgingRetain([NSMutableDictionary dictionary]);
        NSMutableData *result = nil;
        assert(request(drive, &manager, IRP_MJ_CREATE, 0, 0, createRequest(@"new.txt", YES), &result) == STATUS_SUCCESS);
        assert(result.length == 5);
        assert(request(drive, &manager, IRP_MJ_CREATE, 0, 0, createRequest(@"new.txt", YES), NULL) == STATUS_ACCESS_DENIED);
        assert(request(drive, &manager, IRP_MJ_CREATE, 0, 0, createRequest(@"../escape.txt", YES), NULL) != STATUS_SUCCESS);
        // Every fixed-header truncation plus deterministic adversarial fields, including live handle 1.
        const UINT32 operations[] = {IRP_MJ_CREATE, IRP_MJ_READ, IRP_MJ_WRITE, IRP_MJ_QUERY_INFORMATION,
            IRP_MJ_SET_INFORMATION, IRP_MJ_QUERY_VOLUME_INFORMATION, IRP_MJ_DIRECTORY_CONTROL};
        uint32_t random = 0x51DADADA;
        for (size_t operation = 0; operation < sizeof(operations)/sizeof(operations[0]); operation++) {
            for (NSUInteger length = 0; length <= 256; length++) {
                NSMutableData *input = [NSMutableData dataWithLength:length];
                for (NSUInteger byte = 0; byte < length; byte++) { random = random * 1664525u + 1013904223u; ((BYTE *)input.mutableBytes)[byte] = random >> 24; }
                request(drive, &manager, operations[operation], IRP_MN_QUERY_DIRECTORY, 1, input, NULL);
            }
        }
        request(drive, &manager, IRP_MJ_CLOSE, 0, 1, [NSData data], NULL);
        driveFree(&drive->device);
        assert([NSFileManager.defaultManager removeItemAtURL:root error:NULL]);
        puts("RDP bridge sanitizer checks passed: create/overwrite/traversal + 1799 malformed IRPs");
    }
    return 0;
}

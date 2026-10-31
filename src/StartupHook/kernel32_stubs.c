// Stub implementations for Windows P/Invoke functions used by BC service tier on Linux.
// Compiled to libwin32_stubs.so and loaded via NativeLibrary.ResolvingUnmanagedDll.
// Provides no-op/stub implementations for: kernel32, user32, Wintrust, nclcsrts,
// dhcpcsvc, Netapi32, ntdsapi, rpcrt4, advapi32, winspool.

#include <stdint.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef intptr_t HANDLE;

// =============================================================================
// kernel32.dll
// =============================================================================

// --- Job Object (process groups, not needed on Linux) ---
HANDLE OpenJobObject(uint32_t a, int b, const void* c) { return 0; }
HANDLE CreateJobObject(HANDLE a, const void* b) { return (HANDLE)0xDEAD; }
int SetInformationJobObject(HANDLE a, int b, HANDLE c, uint32_t d) { return 1; }
int AssignProcessToJobObject(HANDLE a, HANDLE b) { return 1; }
int IsProcessInJob(HANDLE a, HANDLE b) { return 0; }
int CloseHandle(HANDLE h) { return 1; }

// --- Memory info ---
int GetPhysicallyInstalledSystemMemory(int64_t* totalKB) { *totalKB = 16 * 1024 * 1024; return 1; }

typedef struct {
    uint32_t dwLength;
    uint32_t dwMemoryLoad;
    uint64_t ullTotalPhys;
    uint64_t ullAvailPhys;
    uint64_t ullTotalPageFile;
    uint64_t ullAvailPageFile;
    uint64_t ullTotalVirtual;
    uint64_t ullAvailVirtual;
    uint64_t ullAvailExtendedVirtual;
} MEMORYSTATUSEX;

int GlobalMemoryStatusEx(MEMORYSTATUSEX* ms) {
    ms->dwMemoryLoad = 50;
    ms->ullTotalPhys = 16ULL * 1024 * 1024 * 1024;
    ms->ullAvailPhys = 8ULL * 1024 * 1024 * 1024;
    ms->ullTotalPageFile = 16ULL * 1024 * 1024 * 1024;
    ms->ullAvailPageFile = 8ULL * 1024 * 1024 * 1024;
    ms->ullTotalVirtual = 128ULL * 1024 * 1024 * 1024;
    ms->ullAvailVirtual = 128ULL * 1024 * 1024 * 1024;
    ms->ullAvailExtendedVirtual = 0;
    return 1;
}

// --- Module/library ---
int FreeLibrary(HANDLE h) { return 1; }
HANDLE GetModuleHandle(const void* name) { return 0; }
HANDLE GetModuleHandleW(const void* name) { return 0; }
HANDLE LoadLibraryExW(const void* lpFileName, HANDLE hFile, uint32_t dwFlags) {
    return (HANDLE)0x1234; // fake library handle
}
HANDLE LoadLibraryW(const void* lpFileName) { return (HANDLE)0x1234; }
void* GetProcAddress(HANDLE hModule, const char* lpProcName) { return 0; } // function not found

// --- Performance counter ---
int QueryPerformanceCounter(int64_t* ticks) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    *ticks = ts.tv_sec * 1000000000LL + ts.tv_nsec;
    return 1;
}

// --- NLS string search (return "not found") ---
int FindNLSString(int locale, uint32_t flags, const void* src, int srcCount,
                  const void* find, int findCount, int* found) {
    *found = 0;
    return -1; // CSTR_LESS_THAN means not found
}

int FindStringOrdinal(uint32_t flags, const void* src, int srcCount,
                      const void* find, int findCount, int ignoreCase) {
    return -1; // not found
}

// --- Locale functions ---
int LCIDToLocaleName(uint32_t locale, void* localeName, int localeNameSize, int flags) {
    // A size query (no buffer) gets LOCALE_NAME_MAX_LENGTH, so the caller goes on as if the
    // LCID exists. BC 27/28's WindowsLanguageHelper asks this before it adds a language
    // group's primary culture (zh → 1028 zh-TW) and then calls CultureInfo.GetCultureInfo
    // in a try/catch; BC 29 skips the question off Windows (issue #198).
    if (localeNameSize == 0) {
        return 85;
    }
    // Return empty string (0 chars written) — BC will fall back to invariant culture
    if (localeName && localeNameSize > 0) {
        ((uint16_t*)localeName)[0] = 0; // null-terminate UTF-16
    }
    return 0;
}

int LocaleNameToLCID(const void* localeName, int flags) {
    return 0; // LOCALE_INVARIANT
}

// --- Authentication ---
int LogonUserW(const void* username, const void* domain, const void* password,
               uint32_t logonType, uint32_t logonProvider, HANDLE* phToken) {
    *phToken = (HANDLE)0xAA00; // fake token
    return 1; // success
}

// --- Tick count ---
uint64_t GetTickCount64(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

// --- Computer name (DnsHelper on v26 needs this) ---
int GetComputerNameExW(int format, uint16_t* buffer, int* size) {
    // Return a simple hostname in UTF-16LE
    const char* name = "bcserver";
    int len = 8; // strlen("bcserver")
    if (buffer == 0 || *size < len + 1) {
        *size = len + 1;
        // DnsHelper calls this once with a null buffer and requires Windows'
        // ERROR_MORE_DATA before it allocates the StringBuilder. DllImport's
        // SetLastError reads libc errno on Unix; an exported GetLastError()
        // function does not populate that captured value.
        errno = 234;
        return 0; // ERROR_MORE_DATA triggers retry with correct buffer size
    }
    for (int i = 0; i < len; i++) buffer[i] = (uint16_t)name[i];
    buffer[len] = 0;
    *size = len;
    return 1; // success
}

// --- General ---
uint32_t GetLastError(void) { return 0; }
HANDLE GetCurrentProcess(void) { return (HANDLE)-1; }
uint32_t FormatMessageW(uint32_t a, const void* b, uint32_t c, uint32_t d,
                        void* e, uint32_t f, void* g) { return 0; }

// =============================================================================
// user32.dll — OEM/ANSI encoding + keyboard layout functions
// =============================================================================

// OEM (code page 437) <-> ANSI (code page 1252), as on a Windows tier with the en-US
// locale (issue #113). BC reads these two functions once, in NCLManagedAdapter, to
// build the tables TextEncoding::MSDos goes through; with an identity mapping MSDos
// came out as plain ANSI (e-acute was E9, not the OEM 82).
//
// Base: .NET's windows-437 / windows-1252 best-fit data, one byte at a time:
//   oem2ansi[b] = Encoding(1252).GetBytes(Encoding(437).GetString(b))
//   ansi2oem[b] = Encoding(437).GetBytes(Encoding(1252).GetString(b))
// Three pairs differ from that base, because Microsoft's own code page 437 table maps
// control bytes to glyphs: 0x14 <-> 0xB6 (pilcrow), 0x15 <-> 0xA7 (section sign) and
// 0x0F <-> 0xA4 (currency sign). They are not guesses: with them, BC's own pairing
// fix-up (NCLManagedAdapter.Initialize) reproduces all 16 table entries that a Windows
// container's test results show (euro sign -> 0xB1, 0xC3 -> 0x93, 0xA9 -> 0x14, ...);
// without them it does not.
static const uint8_t oem2ansi[256] = {
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0xA4,
    0x10, 0x11, 0x12, 0x13, 0xB6, 0xA7, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
    0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F,
    0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F,
    0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F,
    0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F,
    0xC7, 0xFC, 0xE9, 0xE2, 0xE4, 0xE0, 0xE5, 0xE7, 0xEA, 0xEB, 0xE8, 0xEF, 0xEE, 0xEC, 0xC4, 0xC5,
    0xC9, 0xE6, 0xC6, 0xF4, 0xF6, 0xF2, 0xFB, 0xF9, 0xFF, 0xD6, 0xDC, 0xA2, 0xA3, 0xA5, 0x50, 0x83,
    0xE1, 0xED, 0xF3, 0xFA, 0xF1, 0xD1, 0xAA, 0xBA, 0xBF, 0xAC, 0xAC, 0xBD, 0xBC, 0xA1, 0xAB, 0xBB,
    0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0x2B, 0x2B, 0xA6, 0xA6, 0x2B, 0x2B, 0x2B, 0x2B, 0x2B,
    0x2B, 0x2D, 0x2D, 0x2B, 0x2D, 0x2B, 0xA6, 0xA6, 0x2B, 0x2B, 0x2D, 0x2D, 0xA6, 0x2D, 0x2B, 0x2D,
    0x2D, 0x2D, 0x2D, 0x2B, 0x2B, 0x2B, 0x2B, 0x2B, 0x2B, 0x2B, 0x2B, 0xA6, 0x5F, 0xA6, 0xA6, 0xAF,
    0x61, 0xDF, 0x47, 0x70, 0x53, 0x73, 0xB5, 0x74, 0x46, 0x54, 0x4F, 0x64, 0x38, 0x66, 0x65, 0x6E,
    0x3D, 0xB1, 0x3D, 0x3D, 0x28, 0x29, 0xF7, 0x98, 0xB0, 0xB7, 0xB7, 0x76, 0x6E, 0xB2, 0xA6, 0xA0,
};
static const uint8_t ansi2oem[256] = {
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
    0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F,
    0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F,
    0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F,
    0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F,
    0x3F, 0x3F, 0x2C, 0x9F, 0x2C, 0x2E, 0x2B, 0xD8, 0x5E, 0x25, 0x53, 0x3C, 0x4F, 0x3F, 0x5A, 0x3F,
    0x3F, 0x60, 0x27, 0x22, 0x22, 0x07, 0x2D, 0x2D, 0x7E, 0x54, 0x73, 0x3E, 0x6F, 0x3F, 0x7A, 0x59,
    0xFF, 0xAD, 0x9B, 0x9C, 0x0F, 0x9D, 0xDD, 0x15, 0x22, 0x63, 0xA6, 0xAE, 0xAA, 0x2D, 0x72, 0x5F,
    0xF8, 0xF1, 0xFD, 0x33, 0x27, 0xE6, 0x14, 0xFA, 0x2C, 0x31, 0xA7, 0xAF, 0xAC, 0xAB, 0x5F, 0xA8,
    0x41, 0x41, 0x41, 0x41, 0x8E, 0x8F, 0x92, 0x80, 0x45, 0x90, 0x45, 0x45, 0x49, 0x49, 0x49, 0x49,
    0x44, 0xA5, 0x4F, 0x4F, 0x4F, 0x4F, 0x99, 0x78, 0x4F, 0x55, 0x55, 0x55, 0x9A, 0x59, 0x5F, 0xE1,
    0x85, 0xA0, 0x83, 0x61, 0x84, 0x86, 0x91, 0x87, 0x8A, 0x82, 0x88, 0x89, 0x8D, 0xA1, 0x8C, 0x8B,
    0x64, 0xA4, 0x95, 0xA2, 0x93, 0x6F, 0x94, 0xF6, 0x6F, 0x97, 0xA3, 0x96, 0x81, 0x79, 0x5F, 0x98,
};

int OemToCharBuffA(const uint8_t* src, uint8_t* dst, int size) {
    for (int i = 0; i < size; i++) dst[i] = oem2ansi[src[i]];
    return 1;
}

int CharToOemBuffA(const uint8_t* src, uint8_t* dst, int size) {
    for (int i = 0; i < size; i++) dst[i] = ansi2oem[src[i]];
    return 1;
}

// Keyboard layout functions — used by Microsoft.Dynamics.Framework.UI for
// keyboard mapping. Return US English defaults on Linux.
// GetKeyboardLayoutName: writes KL identifier string (e.g. "00000409" = US English)
int GetKeyboardLayoutNameW(uint16_t* pwszKLID) {
    // "00000409" in UTF-16LE (US English keyboard)
    const uint16_t us[] = {'0','0','0','0','0','4','0','9', 0};
    memcpy(pwszKLID, us, sizeof(us));
    return 1;
}
// Alias — .NET marshaling may use either name
int GetKeyboardLayoutName(uint16_t* pwszKLID) {
    return GetKeyboardLayoutNameW(pwszKLID);
}

// LoadKeyboardLayout: returns a dummy HKL handle
intptr_t LoadKeyboardLayoutW(const uint16_t* pwszKLID, uint32_t Flags) {
    return (intptr_t)0x04090409; // US English HKL
}
intptr_t LoadKeyboardLayout(const uint16_t* pwszKLID, uint32_t Flags) {
    return LoadKeyboardLayoutW(pwszKLID, Flags);
}

// GetKeyState: returns 0 (key not pressed)
int16_t GetKeyState(int nVirtKey) { return 0; }

// MapVirtualKeyEx: returns 0 (no mapping)
uint32_t MapVirtualKeyExW(uint32_t uCode, uint32_t uMapType, intptr_t dwhkl) { return 0; }
uint32_t MapVirtualKeyEx(uint32_t uCode, uint32_t uMapType, intptr_t dwhkl) { return 0; }

// ToUnicodeEx: returns 1 with a space character (null-terminated).
// KeyboardMapper.ClearKeyboardBuffer loops until this returns 1,
// so returning 0 causes an infinite loop.
int ToUnicodeEx(uint32_t wVirtKey, uint32_t wScanCode, const uint8_t* lpKeyState,
                uint16_t* pwszBuff, int cchBuff, uint32_t wFlags, intptr_t dwhkl) {
    if (cchBuff > 1) {
        pwszBuff[0] = (uint16_t)' ';
        pwszBuff[1] = 0;
    } else if (cchBuff > 0) {
        pwszBuff[0] = 0;
    }
    return 1;
}

// =============================================================================
// Wintrust.dll — Code signing verification
// =============================================================================

// Return TRUST_E_PROVIDER_UNKNOWN (0x800B0001) to skip verification gracefully
uint32_t WinVerifyTrust(HANDLE hwnd, HANDLE actionId, HANDLE trustData) {
    return 0; // S_OK = trusted (skip verification in test mode)
}

// =============================================================================
// rpcrt4.dll — RPC runtime
// =============================================================================

// Generate a sequential UUID using /dev/urandom
int UuidCreateSequential(void* guid) {
    // Fill 16 bytes of GUID with pseudo-random data
    FILE* f = fopen("/dev/urandom", "rb");
    if (f) {
        fread(guid, 16, 1, f);
        fclose(f);
    }
    return 0; // RPC_S_OK
}

// =============================================================================
// nclcsrts.dll — BC native runtime (SPN registration)
// =============================================================================

uint32_t NCL_SpnRegister(const void* a, const void* b, const void* c, int d) {
    return 0; // success
}

// =============================================================================
// dhcpcsvc.dll — DHCP client (not needed for test pipeline)
// =============================================================================

uint32_t DhcpCApiInitialize(uint32_t* version) { *version = 1; return 0; }
void DhcpCApiCleanup(void) {}
uint32_t DhcpRequestParams(uint32_t flags, HANDLE reserved, const void* adapter,
                           HANDLE classId, void* send, void* recd,
                           HANDLE buffer, uint32_t* size, const void* reqId) {
    return 1; // ERROR_INVALID_FUNCTION
}

// =============================================================================
// Netapi32.dll — Network management API
// =============================================================================

uint32_t DsGetDcName(const void* computer, const void* domain, HANDLE guid,
                     const void* site, int flags, HANDLE* info) {
    *info = 0;
    return 1355; // ERROR_NO_SUCH_DOMAIN
}

int NetApiBufferFree(HANDLE buffer) { return 0; } // NERR_Success

// =============================================================================
// ntdsapi.dll — Active Directory services
// =============================================================================

uint32_t DsBind(const void* dc, const void* domain, HANDLE* phDS) {
    *phDS = 0;
    return 1355; // ERROR_NO_SUCH_DOMAIN
}
uint32_t DsUnBind(HANDLE* phDS) { *phDS = 0; return 0; }
uint32_t DsCrackNames(HANDLE hDS, int flags, int offered, int desired,
                      uint32_t count, const void** names, HANDLE* result) {
    *result = 0;
    return 1355;
}
void DsFreeNameResult(HANDLE result) {}
uint32_t DsWriteAccountSpn(HANDLE hDS, int op, const void* acct,
                           uint32_t count, const void** spns) {
    return 1355;
}

// =============================================================================
// libgdiplus — System.Drawing.Common on Linux (stub for font enumeration)
// =============================================================================

typedef int GpStatus;
typedef struct { uint32_t GdiplusVersion; void* DebugEventCallback; int SuppressBackgroundThread; int SuppressExternalCodecs; } GdiplusStartupInput;
typedef struct { void* NotificationHook; void* NotificationUnhook; } GdiplusStartupOutput;

GpStatus GdiplusStartup(HANDLE* token, const GdiplusStartupInput* input, GdiplusStartupOutput* output) {
    *token = (HANDLE)1;
    if (output) { output->NotificationHook = 0; output->NotificationUnhook = 0; }
    return 0; // Ok
}
void GdiplusShutdown(HANDLE token) {}
GpStatus GdipNewInstalledFontCollection(HANDLE* fontCollection) {
    *fontCollection = (HANDLE)0xF0F0;
    return 0;
}
GpStatus GdipGetFontCollectionFamilyCount(HANDLE fontCollection, int* count) {
    *count = 0; // No fonts
    return 0;
}
GpStatus GdipGetFontCollectionFamilyList(HANDLE fontCollection, int max, HANDLE* families, int* count) {
    *count = 0;
    return 0;
}

// =============================================================================
// httpapi.dll — HTTP Server API (HttpSys replacement stubs)
// =============================================================================

// HTTP_INITIALIZE_SERVER = 1, HTTP_INITIALIZE_CONFIG = 2
uint32_t HttpInitialize(uint32_t version, uint32_t flags, void* reserved) { return 0; } // NO_ERROR
uint32_t HttpTerminate(uint32_t flags, void* reserved) { return 0; }

uint32_t HttpCreateServerSession(uint32_t version, uint64_t* sessionId, uint32_t reserved) {
    *sessionId = 0x1234;
    return 0;
}
uint32_t HttpCloseServerSession(uint64_t sessionId) { return 0; }

uint32_t HttpCreateUrlGroup(uint64_t sessionId, uint64_t* groupId, uint32_t reserved) {
    *groupId = 0x5678;
    return 0;
}
uint32_t HttpCloseUrlGroup(uint64_t groupId) { return 0; }

uint32_t HttpSetUrlGroupProperty(uint64_t groupId, int property, void* info, uint32_t infoLen) {
    return 0;
}

uint32_t HttpAddUrlToUrlGroup(uint64_t groupId, const void* url, uint64_t context, uint32_t reserved) {
    return 0;
}
uint32_t HttpRemoveUrlFromUrlGroup(uint64_t groupId, const void* url, uint32_t flags) {
    return 0;
}

uint32_t HttpCreateRequestQueue(uint32_t version, const void* name, void* securityAttributes,
                                uint32_t flags, HANDLE* requestQueueHandle) {
    *requestQueueHandle = (HANDLE)0xABCD;
    return 0;
}
uint32_t HttpCloseRequestQueue(HANDLE requestQueueHandle) { return 0; }

uint32_t HttpSetRequestQueueProperty(HANDLE requestQueue, int property,
                                     void* info, uint32_t infoLen, uint32_t reserved, void* overlapped) {
    return 0;
}

uint32_t HttpReceiveHttpRequest(HANDLE requestQueue, uint64_t requestId, uint32_t flags,
                                void* requestBuffer, uint32_t requestBufferLen,
                                uint32_t* bytesReturned, void* overlapped) {
    return 87; // ERROR_INVALID_PARAMETER — will cause async wait
}

uint32_t HttpSendHttpResponse(HANDLE requestQueue, uint64_t requestId, uint32_t flags,
                              void* response, void* cachePolicy, uint32_t* bytesSent,
                              void* reserved1, uint32_t reserved2, void* overlapped, void* logData) {
    if (bytesSent) *bytesSent = 0;
    return 0;
}

uint32_t HttpWaitForDisconnectEx(HANDLE requestQueue, uint64_t connectionId,
                                 uint32_t reserved, void* overlapped) {
    return 997; // ERROR_IO_PENDING
}

uint32_t HttpSetServerSessionProperty(uint64_t sessionId, int property, void* info, uint32_t infoLen) {
    return 0;
}

// =============================================================================
// advapi32.dll — Security/Registry (may be needed later)
// =============================================================================

// --- Registry access (SqlClient needs this for connection string parsing) ---
int RegOpenKeyExW(HANDLE hKey, const void* subKey, uint32_t options, uint32_t samDesired, HANDLE* result) {
    *result = 0;
    return 2; // ERROR_FILE_NOT_FOUND — key doesn't exist
}

int RegQueryValueExW(HANDLE hKey, const void* valueName, uint32_t* reserved,
                     uint32_t* type, void* data, uint32_t* cbData) {
    return 2; // ERROR_FILE_NOT_FOUND
}

int RegCloseKey(HANDLE hKey) { return 0; }

HANDLE RegisterEventSourceW(const void* server, const void* source) {
    return (HANDLE)0xEEEE;
}
int ReportEventW(HANDLE h, uint16_t type, uint16_t cat, uint32_t id,
                 void* sid, uint16_t numStrings, uint32_t dataSize,
                 const void** strings, void* rawData) {
    return 1;
}
int DeregisterEventSource(HANDLE h) { return 1; }

// =============================================================================
// winspool.drv — print spooler. This host has no printers.
//
// BC 29's Nav.Types PrinterHelper.GetPrinters() (reached while building a report
// request page) P/Invokes these; without a library it dies with DllNotFoundException
// (issue #108). The answer a Windows machine with no printers gives is "success,
// zero printers", so that is what EnumPrinters returns. CharSet.Auto resolves to the
// ANSI entry point on Linux, hence all three spellings of each name.
// =============================================================================
int GetDefaultPrinterW(uint16_t* buf, uint32_t* size) { return 0; }  // no default printer
int GetDefaultPrinterA(char* buf, uint32_t* size) { return 0; }
int GetDefaultPrinter(void* buf, uint32_t* size) { return 0; }

int EnumPrintersW(uint32_t flags, const void* name, uint32_t level, void* buf,
                  uint32_t cb, uint32_t* needed, uint32_t* returned) {
    if (needed) *needed = 0;
    if (returned) *returned = 0;
    return 1;
}
int EnumPrintersA(uint32_t flags, const void* name, uint32_t level, void* buf,
                  uint32_t cb, uint32_t* needed, uint32_t* returned) {
    return EnumPrintersW(flags, name, level, buf, cb, needed, returned);
}
int EnumPrinters(uint32_t flags, const void* name, uint32_t level, void* buf,
                 uint32_t cb, uint32_t* needed, uint32_t* returned) {
    return EnumPrintersW(flags, name, level, buf, cb, needed, returned);
}

int OpenPrinterW(const void* name, HANDLE* h, const void* defaults) { if (h) *h = 0; return 0; }
int OpenPrinterA(const void* name, HANDLE* h, const void* defaults) { if (h) *h = 0; return 0; }
int OpenPrinter(const void* name, HANDLE* h, const void* defaults) { if (h) *h = 0; return 0; }

int GetPrinterW(HANDLE h, int level, void* buf, int cb, int* needed) { if (needed) *needed = 0; return 0; }
int GetPrinterA(HANDLE h, int level, void* buf, int cb, int* needed) { if (needed) *needed = 0; return 0; }
int GetPrinter(HANDLE h, int level, void* buf, int cb, int* needed) { if (needed) *needed = 0; return 0; }

int ClosePrinter(HANDLE h) { return 1; }

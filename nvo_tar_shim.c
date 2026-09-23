/* tar.exe shim for Wine: translates Windows-bundled bsdtar usage
 *   tar.exe -xf "<zip>" [-C "<dir>"]
 * into a 7-Zip extraction, because Wine ships no tar.exe.
 * Freestanding: no CRT, links only against kernel32 imports.
 *
 * Build (LLVM toolchain - what the setup script embeds):
 *   ./build_shim.sh            # rebuilds and re-embeds the blob below
 *
 * Manual equivalent:
 *   llvm-dlltool -m i386:x86-64 -d kernel32.def -l kernel32.lib
 *   clang --target=x86_64-pc-windows-msvc -c nvo_tar_shim.c -o nvo_tar_shim.obj \
 *         -ffreestanding -fno-stack-protector -mno-stack-arg-probe -fno-builtin -O2
 *   lld-link /entry:entry /subsystem:console /nodefaultlib /Brepro /out:tar.exe \
 *         nvo_tar_shim.obj kernel32.lib
 *
 * (/Brepro keeps the output deterministic so re-embedding is verifiable.)
 *
 * Or with mingw-w64 (equivalent):
 *   x86_64-w64-mingw32-gcc -O2 -s -nostdlib -e entry nvo_tar_shim.c -lkernel32 -o tar.exe
 */
typedef unsigned char BYTE;
typedef unsigned short WCHAR;
typedef unsigned int DWORD;
typedef int BOOL;
typedef void *HANDLE;
typedef void *LPVOID;
typedef const WCHAR *LPCWSTR;
typedef WCHAR *LPWSTR;

typedef struct { DWORD lo, hi; } FILETIME;
typedef struct {
    DWORD cb;
    LPWSTR lpReserved, lpDesktop, lpTitle;
    DWORD dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    unsigned short wShowWindow, cbReserved2;
    BYTE *lpReserved2;
    HANDLE hStdInput, hStdOutput, hStdError;
} STARTUPINFOW;
typedef struct { HANDLE hProcess, hThread; DWORD dwProcessId, dwThreadId; } PROCESS_INFORMATION;

__declspec(dllimport) LPWSTR GetCommandLineW(void);
__declspec(dllimport) DWORD  GetCurrentDirectoryW(DWORD, LPWSTR);
__declspec(dllimport) DWORD  GetModuleFileNameW(HANDLE, LPWSTR, DWORD);
__declspec(dllimport) DWORD  GetFileAttributesW(LPCWSTR);
__declspec(dllimport) HANDLE CreateFileW(LPCWSTR, DWORD, DWORD, LPVOID, DWORD, DWORD, HANDLE);
__declspec(dllimport) BOOL   WriteFile(HANDLE, const void *, DWORD, DWORD *, LPVOID);
__declspec(dllimport) BOOL   CreateProcessW(LPCWSTR, LPWSTR, LPVOID, LPVOID, BOOL, DWORD, LPVOID, LPCWSTR, STARTUPINFOW *, PROCESS_INFORMATION *);
__declspec(dllimport) DWORD  WaitForSingleObject(HANDLE, DWORD);
__declspec(dllimport) BOOL   GetExitCodeProcess(HANDLE, DWORD *);
__declspec(dllimport) BOOL   CloseHandle(HANDLE);
__declspec(dllimport) void   ExitProcess(DWORD);

#define INVALID_ATTRIBUTES 0xFFFFFFFFu
#define CREATE_ALWAYS 2u
#define OPEN_ALWAYS 4u
#define GENERIC_WRITE 0x40000000u
#define FILE_APPEND_DATA 0x0004u
#define FILE_ATTRIBUTE_NORMAL 0x80u
#define CREATE_NO_WINDOW 0x08000000u
#define INFINITE 0xFFFFFFFFu

/* ---- tiny wide-string helpers ---- */
static unsigned wslen(const WCHAR *s){ unsigned n=0; while(s[n]) n++; return n; }
static void wscpy(WCHAR *d, const WCHAR *s){ while((*d++=*s++)); }
static void wscat(WCHAR *d, const WCHAR *s){ while(*d) d++; while((*d++=*s++)); }
static int  wseq(const WCHAR *a, const WCHAR *b){ while(*a&&*b){ if(*a!=*b) return 0; a++; b++; } return *a==*b; }

/* ---- buffers (static: avoids stack probing) ---- */
static WCHAR tok[2048];
static WCHAR archive[2048];
static WCHAR target[2048];
static WCHAR cmd[8192];
static WCHAR exepath[2048];
static WCHAR logpath[2048];
static STARTUPINFOW si;
static PROCESS_INFORMATION pi;

static void logline(const WCHAR *s){
    static WCHAR logbuf[8196];
    DWORD w, n = 0;
    HANDLE h;
    /* assemble line + CRLF first so a single WriteFile makes the append
       atomic (two shim instances can't interleave a line and its newline) */
    while(s[n] && n < 8192) logbuf[n] = s[n], n++;
    logbuf[n++] = L'\r';
    logbuf[n++] = L'\n';
    /* FILE_APPEND_DATA *alone* (never OR'd with GENERIC_WRITE/FILE_WRITE_DATA):
       every write goes to EOF, no seek needed, and concurrent shim instances
       append instead of clobbering.  OPEN_ALWAYS creates it if missing. */
    h = CreateFileW(logpath, FILE_APPEND_DATA, 3 /*READ|WRITE share*/, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if(h==(HANDLE)-1 || h==0) return;
    /* WriteFile wants bytes; WCHAR is 2 bytes */
    WriteFile(h, logbuf, n*2, &w, 0);
    CloseHandle(h);
}

/* pull next whitespace-separated token, honouring double quotes */
static WCHAR *next_tok(WCHAR **pp, WCHAR *out, int cap){
    WCHAR *p = *pp;
    int n=0, q=0;
    while(*p==' '||*p=='\t') p++;
    if(!*p){ out[0]=0; *pp=p; return 0; }
    while(*p){
        if(*p=='"'){ q=!q; p++; continue; }
        if(!q && (*p==' '||*p=='\t')) break;
        if(n<cap-1) out[n++]=*p;
        p++;
    }
    out[n]=0;
    *pp=p;
    return out;
}

static int file_exists(const WCHAR *p){
    return GetFileAttributesW(p) != INVALID_ATTRIBUTES;
}

/* find a usable 7z.exe: next to tar.exe, then Program Files, then PATH */
static void find_7z(void){
    DWORD n = GetModuleFileNameW(0, exepath, 2048);
    if(n){
        unsigned i=n;
        while(i>0 && exepath[i-1]!='\\' && exepath[i-1]!='/') i--;
        exepath[i]=0;                 /* directory (with trailing sep) */
        wscpy(cmd, exepath);          /* reuse cmd as scratch */
        wscat(cmd, L"7z.exe");
        if(file_exists(cmd)){ wscpy(exepath, cmd); return; }
    }
    if(file_exists(L"C:\\Program Files\\7-Zip\\7z.exe")){ wscpy(exepath, L"C:\\Program Files\\7-Zip\\7z.exe"); return; }
    if(file_exists(L"C:\\Program Files (x86)\\7-Zip\\7z.exe")){ wscpy(exepath, L"C:\\Program Files (x86)\\7-Zip\\7z.exe"); return; }
    wscpy(exepath, L"7z.exe");        /* let CreateProcess search PATH */
}

void entry(void){
    WCHAR *p = GetCommandLineW();
    int pendingC = 0;

    /* log file lives next to tar.exe */
    {
        DWORD n = GetModuleFileNameW(0, logpath, 2048);
        unsigned i=n;
        while(i>0 && logpath[i-1]!='\\' && logpath[i-1]!='/') i--;
        logpath[i]=0;
        wscat(logpath, L"tar_shim.log");
    }

    next_tok(&p, tok, 2048);                 /* skip argv[0] */
    archive[0]=0; target[0]=0;
    while(next_tok(&p, tok, 2048)){
        if(wseq(tok, L"-C") || wseq(tok, L"-c")){ pendingC=1; continue; }
        if(tok[0]=='-') continue;            /* flags: -xf, -x, -f, ... */
        if(pendingC){ wscpy(target, tok); pendingC=0; }
        else wscpy(archive, tok);
    }

    if(!target[0]) GetCurrentDirectoryW(2048, target);
    /* 7-Zip takes -o<dir> with no space.  A trailing backslash immediately
       before the closing quote would escape that quote under Windows command
       line parsing (CommandLineToArgvW), swallowing the archive argument --
       so strip trailing separators. */
    {
        unsigned n = wslen(target);
        while(n > 0 && (target[n-1] == L'\\' || target[n-1] == L'/')) target[--n] = 0;
        if(n == 0){ target[0] = L'.'; target[1] = 0; }
    }
    if(!archive[0]){ logline(L"tar_shim: no archive argument"); ExitProcess(2); }

    find_7z();

    wscpy(cmd, L"\"");
    wscat(cmd, exepath);
    wscat(cmd, L"\" x -y -aoa -bd -bso0 -bsp0 -o\"");
    wscat(cmd, target);
    wscat(cmd, L"\" \"");
    wscat(cmd, archive);
    wscat(cmd, L"\"");

    logline(cmd);

    si.cb = sizeof(STARTUPINFOW);
    if(!CreateProcessW(0, cmd, 0, 0, 0, CREATE_NO_WINDOW, 0, 0, &si, &pi)){
        logline(L"tar_shim: CreateProcessW failed");
        ExitProcess(3);
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    {
        DWORD rc = 1;
        GetExitCodeProcess(pi.hProcess, &rc);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        ExitProcess(rc);
    }
}

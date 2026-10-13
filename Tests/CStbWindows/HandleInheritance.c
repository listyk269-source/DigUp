// Include the production translation unit: exercise stb's real private reader/writer open functions.
#include <windows.h>
#include <stdint.h>
#include <io.h>
#define STBI_WINDOWS_UTF8
#define STBIW_WINDOWS_UTF8
#include "../../scripts/stb.c"

static int check_handle(const wchar_t *path, int write_mode) {
    char utf8[4096];
    if (!WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8, sizeof(utf8), NULL, NULL)) return 10;
    FILE *stream = write_mode ? stbiw__fopen(utf8, "wb") : stbi__fopen(utf8, "rb");
    if (!stream) return 11;
    if (write_mode && (fwrite("synthetic", 1, 9, stream) != 9 || fflush(stream) != 0)) {
        fclose(stream);
        return 12;
    }
    DWORD flags = 0;
    if (!GetHandleInformation((HANDLE)_get_osfhandle(_fileno(stream)), &flags)) {
        fclose(stream);
        return 13;
    }
    SECURITY_ATTRIBUTES attributes = {sizeof(attributes), NULL, TRUE};
    HANDLE release = CreateEventW(&attributes, TRUE, FALSE, NULL);
    if (!release) { fclose(stream); return 14; }
    wchar_t executable[32768], command[32768];
    DWORD length = GetModuleFileNameW(NULL, executable, 32768);
    if (!length || length >= 32768 ||
        swprintf(command, 32768, L"\"%ls\" --child %llu", executable,
                 (unsigned long long)(uintptr_t)release) < 0) {
        CloseHandle(release);
        fclose(stream);
        return 15;
    }
    STARTUPINFOW startup = {sizeof(startup)};
    PROCESS_INFORMATION child = {0};
    // The releaser event is intentionally inherited; the stb FILE must not be inherited with it.
    if (!CreateProcessW(NULL, command, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &startup, &child)) {
        CloseHandle(release);
        fclose(stream);
        return 16;
    }
    fclose(stream);
    DWORD child_status = 0;
    int child_alive = GetExitCodeProcess(child.hProcess, &child_status) && child_status == STILL_ACTIVE;
    SetLastError(0);
    HANDLE exclusive = CreateFileW(path, GENERIC_READ, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD exclusive_error = exclusive == INVALID_HANDLE_VALUE ? GetLastError() : 0;
    if (exclusive != INVALID_HANDLE_VALUE) CloseHandle(exclusive);
    // End the real child only after checking access, so success cannot depend on a short child lifetime.
    SetEvent(release);
    DWORD waited = WaitForSingleObject(child.hProcess, 5000);
    if (waited != WAIT_OBJECT_0) {
        TerminateProcess(child.hProcess, 1);
        WaitForSingleObject(child.hProcess, 5000);
    }
    DWORD child_exit = 1;
    GetExitCodeProcess(child.hProcess, &child_exit);
    CloseHandle(child.hThread);
    CloseHandle(child.hProcess);
    CloseHandle(release);
    printf("{\"mode\":\"%s\",\"inheritable\":%s,\"childAliveDuringCheck\":%s,"
           "\"exclusiveOpenError\":%lu,\"childExit\":%lu}\n",
           write_mode ? "wb" : "rb", (flags & HANDLE_FLAG_INHERIT) ? "true" : "false",
           child_alive ? "true" : "false", exclusive_error, child_exit);
    return !(flags & HANDLE_FLAG_INHERIT) && child_alive && exclusive_error == 0 &&
           waited == WAIT_OBJECT_0 && child_exit == 0 ? 0 : 17;
}

int wmain(int argc, wchar_t **argv) {
    if (argc == 3 && wcscmp(argv[1], L"--child") == 0) {
        HANDLE release = (HANDLE)(uintptr_t)wcstoull(argv[2], NULL, 10);
        DWORD waited = WaitForSingleObject(release, 10000);
        CloseHandle(release);
        return waited == WAIT_OBJECT_0 ? 0 : 20;
    }
    if (argc != 2) return 21;
    int result = check_handle(argv[1], 1);
    if (!result) result = check_handle(argv[1], 0);
    DeleteFileW(argv[1]);
    return result;
}

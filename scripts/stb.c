// The pinned stb implementations, once; copied into Vendor/stb by the fetch scripts.
#ifdef _WIN32
#include <errno.h>
#include <stdio.h>
#include <wchar.h>

// CRT file streams otherwise create inheritable handles. A concurrent Swift Process launch could
// keep an input or a completed preview open after fclose, blocking reads, replacement or cleanup.
// Add N at open time: clearing HANDLE_FLAG_INHERIT after opening would still leave a race.
static int digup_stb_private_mode(wchar_t result[16], const wchar_t *mode) {
    size_t length = wcslen(mode);
    if (length + 2 > 16) {
        errno = EINVAL;
        return 0;
    }
    wmemcpy(result, mode, length);
    result[length] = L'N';
    result[length + 1] = 0;
    return 1;
}

#if defined(_MSC_VER) && _MSC_VER >= 1400
static errno_t digup_stb_wfopen_s(FILE **stream, const wchar_t *path, const wchar_t *mode) {
    wchar_t private_mode[16];
    if (!digup_stb_private_mode(private_mode, mode)) {
        *stream = NULL;
        return EINVAL;
    }
    return _wfopen_s(stream, path, private_mode);
}
#define _wfopen_s digup_stb_wfopen_s
#else
static FILE *digup_stb_wfopen(const wchar_t *path, const wchar_t *mode) {
    wchar_t private_mode[16];
    if (!digup_stb_private_mode(private_mode, mode)) return NULL;
    return _wfopen(path, private_mode);
}
#define _wfopen digup_stb_wfopen
#endif
#endif

#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image.h"
#include "stb_image_write.h"
#include "stb_image_resize2.h"

#ifdef _WIN32
#undef _wfopen_s
#undef _wfopen
#endif

// iconv 是 iOS 与 Linux 均提供的编码转换接口，错误输入不会静默丢字。
#include <iconv.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "CLibMobi.h"

char *miolib_decode_text(const char *input, size_t size, const char *encoding, size_t *output_size) {
    if (size > 128 * 1024 * 1024) return NULL;
    iconv_t converter = iconv_open("UTF-8", encoding);
    if (converter == (iconv_t)-1) return NULL;
    size_t capacity = size * 4 + 16;
    char *buffer = malloc(capacity);
    if (!buffer) { iconv_close(converter); return NULL; }
    char *source = (char *)input, *destination = buffer;
    size_t remaining = size, available = capacity - 1;
    size_t result = iconv(converter, &source, &remaining, &destination, &available);
    iconv_close(converter);
    if (result == (size_t)-1 || remaining != 0) { free(buffer); return NULL; }
    *destination = '\0';
    *output_size = (size_t)(destination - buffer);
    return buffer;
}

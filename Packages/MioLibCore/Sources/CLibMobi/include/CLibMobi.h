// 将上游 libmobi 的稳定 C 接口公开给 Swift 转换层。
#include "mobi.h"
// 返回的 UTF-8 字符串由调用方使用 free 释放。
char *miolib_decode_text(const char *input, size_t size, const char *encoding, size_t *output_size);

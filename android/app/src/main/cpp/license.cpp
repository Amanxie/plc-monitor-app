// 授权校验核心（native 层）
//
// 设计要点：
//   · 盐不以明文形式出现：拆成 3 段，各自与不同 key 异或后存成常量数组，
//     运行时拼回内存并立即使用，用完 memset 清零。
//   · 校验全过程在 native 完成：Dart 侧只拿到 0/1，无法从 Dart 代码里读到盐。
//   · 附带签名指纹比对：包体被二次打包（换签名）后指纹不符，授权直接判失败。
//
// 对外接口（供 Dart FFI 调用，C ABI）：
//   int  plc_license_verify(const char* code14);   // 1 通过 / 0 失败
//   int  plc_license_sig_ok(const char* sha256hex); // 1 签名相符 / 0 不符
//   int  plc_license_version(void);                 // 算法版本号

#include <stdint.h>
#include <string.h>
#include <stdio.h>

// ---------------------------------------------------------------- MD5

namespace {

struct Md5Ctx {
  uint32_t a, b, c, d;
  uint64_t bits;
  unsigned char buf[64];
};

inline uint32_t rotl(uint32_t x, int c) { return (x << c) | (x >> (32 - c)); }

const uint32_t K[64] = {
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a,
    0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340,
    0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8,
    0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
    0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92,
    0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};

const int S[64] = {7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                   5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20,
                   4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                   6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21};

void md5Block(Md5Ctx* c, const unsigned char* p) {
  uint32_t m[16];
  for (int i = 0; i < 16; i++) {
    m[i] = (uint32_t)p[i * 4] | ((uint32_t)p[i * 4 + 1] << 8) |
           ((uint32_t)p[i * 4 + 2] << 16) | ((uint32_t)p[i * 4 + 3] << 24);
  }
  uint32_t a = c->a, b = c->b, cc = c->c, d = c->d;
  for (int i = 0; i < 64; i++) {
    uint32_t f;
    int g;
    if (i < 16) {
      f = (b & cc) | (~b & d);
      g = i;
    } else if (i < 32) {
      f = (d & b) | (~d & cc);
      g = (5 * i + 1) & 15;
    } else if (i < 48) {
      f = b ^ cc ^ d;
      g = (3 * i + 5) & 15;
    } else {
      f = cc ^ (b | ~d);
      g = (7 * i) & 15;
    }
    uint32_t tmp = d;
    d = cc;
    cc = b;
    b = b + rotl(a + f + K[i] + m[g], S[i]);
    a = tmp;
  }
  c->a += a;
  c->b += b;
  c->c += cc;
  c->d += d;
}

void md5Init(Md5Ctx* c) {
  c->a = 0x67452301;
  c->b = 0xefcdab89;
  c->c = 0x98badcfe;
  c->d = 0x10325476;
  c->bits = 0;
}

void md5Update(Md5Ctx* c, const void* data, size_t len) {
  const unsigned char* p = (const unsigned char*)data;
  size_t used = (size_t)((c->bits >> 3) & 63);
  c->bits += (uint64_t)len << 3;
  if (used) {
    size_t freeBytes = 64 - used;
    if (len < freeBytes) {
      memcpy(c->buf + used, p, len);
      return;
    }
    memcpy(c->buf + used, p, freeBytes);
    md5Block(c, c->buf);
    p += freeBytes;
    len -= freeBytes;
  }
  while (len >= 64) {
    md5Block(c, p);
    p += 64;
    len -= 64;
  }
  if (len) memcpy(c->buf, p, len);
}

void md5Final(Md5Ctx* c, unsigned char out[16]) {
  static const unsigned char pad[64] = {0x80};
  unsigned char lenBytes[8];
  uint64_t bits = c->bits;
  for (int i = 0; i < 8; i++) lenBytes[i] = (unsigned char)((bits >> (8 * i)) & 0xFF);
  size_t used = (size_t)((c->bits >> 3) & 63);
  size_t padLen = (used < 56) ? (56 - used) : (120 - used);
  md5Update(c, pad, padLen);
  md5Update(c, lenBytes, 8);
  uint32_t v[4] = {c->a, c->b, c->c, c->d};
  for (int i = 0; i < 4; i++) {
    out[i * 4] = (unsigned char)(v[i] & 0xFF);
    out[i * 4 + 1] = (unsigned char)((v[i] >> 8) & 0xFF);
    out[i * 4 + 2] = (unsigned char)((v[i] >> 16) & 0xFF);
    out[i * 4 + 3] = (unsigned char)((v[i] >> 24) & 0xFF);
  }
}

// ---------------------------------------------------------------- 盐

// 21 字节，分 3 段异或存储（key 分别为 0x5A / 0xA7 / 0x3D）
const unsigned char S1[7] = {0x22, 0x33, 0x3F, 0x3D, 0x35, 0x34, 0x3D};
const unsigned char S2[7] = {0xC6, 0xCE, 0xC0, 0xC6, 0xC8, 0xDD, 0xCE};
const unsigned char S3[7] = {0x59, 0x52, 0x53, 0x5A, 0x55, 0x48, 0x5C};

const int SALT_LEN = 21;

__attribute__((noinline)) void assembleSalt(unsigned char* out) {
  for (int i = 0; i < 7; i++) out[i] = S1[i] ^ 0x5A;
  for (int i = 0; i < 7; i++) out[7 + i] = S2[i] ^ 0xA7;
  for (int i = 0; i < 7; i++) out[14 + i] = S3[i] ^ 0x3D;
}

__attribute__((noinline)) void wipe(void* p, size_t n) {
  volatile unsigned char* q = (volatile unsigned char*)p;
  while (n--) *q++ = 0;
}

int hexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// ---------------------------------------------------------------- 签名基准
// 由 Gradle 在编译期注入：-DEXPECTED_SIG="EC15...7C0E"
#ifndef EXPECTED_SIG
#define EXPECTED_SIG "0000000000000000000000000000000000000000000000000000000000000000"
#endif

}  // namespace

extern "C" {

// 注意：CMake 开了 -fvisibility=hidden，导出函数必须显式标 default 可见性，
// 否则 Dart FFI 查符号会失败。

__attribute__((visibility("default"))) int plc_license_version(void) { return 106; }

// 设备码规范化：只保留字母数字并转大写，取末 8 位（与 gen_license.dart 一致）
static int normalizeDevice(const char* raw, char out[8]) {
  if (!raw) return 0;
  char buf[64];
  int n = 0;
  for (const char* p = raw; *p && n < 64; p++) {
    char c = *p;
    if (c >= '0' && c <= '9') {
      buf[n++] = c;
    } else if (c >= 'a' && c <= 'z') {
      buf[n++] = (char)(c - 'a' + 'A');
    } else if (c >= 'A' && c <= 'Z') {
      buf[n++] = c;
    }
  }
  if (n < 8) {
    wipe(buf, sizeof(buf));
    return 0;
  }
  for (int i = 0; i < 8; i++) out[i] = buf[n - 8 + i];
  wipe(buf, sizeof(buf));
  return 1;
}

// 14 位码校验（一码一机）：前 8 位 + 盐 + 设备码 8 位 → MD5 → 取后 6 位比对
__attribute__((visibility("default"))) int plc_license_verify_dev(const char* code14,
                                                                 const char* deviceTag) {
  if (!code14) return 0;
  size_t n = strlen(code14);
  if (n != 14) return 0;

  char body[8];
  for (int i = 0; i < 8; i++) {
    char c = code14[i];
    int ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    if (!ok) return 0;
    body[i] = c;
  }

  char dev[8];
  if (!normalizeDevice(deviceTag, dev)) return 0;

  unsigned char salt[32];
  memset(salt, 0, sizeof(salt));
  assembleSalt(salt);

  Md5Ctx ctx;
  md5Init(&ctx);
  md5Update(&ctx, body, 8);
  md5Update(&ctx, salt, (size_t)SALT_LEN);
  md5Update(&ctx, dev, 8);
  unsigned char digest[16];
  md5Final(&ctx, digest);
  wipe(salt, sizeof(salt));
  wipe(dev, sizeof(dev));

  // 转成 32 位大写十六进制，取末 6 位
  static const char* HEX = "0123456789ABCDEF";
  char hex[33];
  for (int i = 0; i < 16; i++) {
    hex[i * 2] = HEX[(digest[i] >> 4) & 0xF];
    hex[i * 2 + 1] = HEX[digest[i] & 0xF];
  }
  hex[32] = 0;
  const char* tail = hex + 26;

  int match = 1;
  for (int i = 0; i < 6; i++) {
    char a = code14[8 + i];
    if (a >= 'a' && a <= 'f') a = (char)(a - 'a' + 'A');
    if (a != tail[i]) match = 0;
  }
  wipe(digest, sizeof(digest));
  wipe(hex, sizeof(hex));
  return match;
}

// 签名指纹比对（忽略大小写与冒号）
__attribute__((visibility("default"))) int plc_license_sig_ok(const char* sha256hex) {
  if (!sha256hex) return 0;
  char clean[65];
  int j = 0;
  for (const char* p = sha256hex; *p && j < 64; p++) {
    if (*p == ':' || *p == ' ') continue;
    char c = *p;
    if (c >= 'a' && c <= 'f') c = (char)(c - 'a' + 'A');
    clean[j++] = c;
  }
  if (j != 64) return 0;
  clean[64] = 0;
  return strcmp(clean, EXPECTED_SIG) == 0 ? 1 : 0;
}

}  // extern "C"

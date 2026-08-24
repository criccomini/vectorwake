#include "png.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zlib.h>

static void be32(unsigned char *p, unsigned long v) {
    p[0] = (unsigned char)(v >> 24);
    p[1] = (unsigned char)(v >> 16);
    p[2] = (unsigned char)(v >> 8);
    p[3] = (unsigned char)v;
}

static void chunk(FILE *f, const char *tag, const unsigned char *data, unsigned long n) {
    unsigned char head[8];
    unsigned char crcb[4];
    unsigned long crc;
    be32(head, n);
    memcpy(head + 4, tag, 4);
    fwrite(head, 1, 8, f);
    if (n) fwrite(data, 1, n, f);
    crc = crc32(crc32(0L, (const Bytef *)tag, 4), (const Bytef *)data, (uInt)n);
    be32(crcb, crc);
    fwrite(crcb, 1, 4, f);
}

int png_write(const char *path, const unsigned char *rgb, int w, int h) {
    /* One filter byte per row, and the filter is none: these are renders
     * rather than photographs, and zlib on raw rows is close enough. */
    unsigned long stride = 1 + (unsigned long)w * 3;
    unsigned long raw_n = (unsigned long)h * stride;
    unsigned char *raw = malloc(raw_n);
    unsigned long comp_n;
    unsigned char *comp;
    unsigned char ihdr[13];
    FILE *f;
    int y;
    if (!raw) return 0;
    for (y = 0; y < h; y++) {
        raw[(unsigned long)y * stride] = 0;
        memcpy(raw + (unsigned long)y * stride + 1,
               rgb + (unsigned long)y * (unsigned long)w * 3, (size_t)w * 3);
    }
    comp_n = compressBound(raw_n);
    comp = malloc(comp_n);
    if (!comp || compress2(comp, &comp_n, raw, raw_n, 9) != Z_OK) {
        free(raw);
        free(comp);
        return 0;
    }
    free(raw);
    f = fopen(path, "wb");
    if (!f) {
        free(comp);
        return 0;
    }
    fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
    be32(ihdr, (unsigned long)w);
    be32(ihdr + 4, (unsigned long)h);
    ihdr[8] = 8;   /* bit depth */
    ihdr[9] = 2;   /* truecolor */
    ihdr[10] = ihdr[11] = ihdr[12] = 0;
    chunk(f, "IHDR", ihdr, 13);
    chunk(f, "IDAT", comp, comp_n);
    chunk(f, "IEND", NULL, 0);
    fclose(f);
    free(comp);
    return 1;
}

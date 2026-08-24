/* Write an 8-bit RGB PNG. zlib does the compression; the rest is header. */
#ifndef PNG_H
#define PNG_H
int png_write(const char *path, const unsigned char *rgb, int w, int h);
#endif

/*
 * pdl_png.c - libpng direct bindings for PDL
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <errno.h>
#include <png.h>

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "pdl.h"
#include "pdlcore.h"

/* ------------------------------------------------------------------ */
/* Error handling                                                       */
/* ------------------------------------------------------------------ */
typedef struct {
    jmp_buf jmpbuf;
    char    msg[256];
} PngErrCtx;

static void png_error_fn(png_structp png, png_const_charp msg) {
    PngErrCtx *ctx = (PngErrCtx *)png_get_error_ptr(png);
    strncpy(ctx->msg, msg, sizeof(ctx->msg) - 1);
    ctx->msg[sizeof(ctx->msg) - 1] = '\0';
    longjmp(ctx->jmpbuf, 1);
}

static void png_warn_fn(png_structp png, png_const_charp msg) {
    (void)png; (void)msg;
}

/* ------------------------------------------------------------------ */
/* rpng - PDLポインタをパラメータで受け取る                             */
/* ------------------------------------------------------------------ */
SV *pdl_rpng(char *filename, Core *PDL) {
    FILE        *fp   = NULL;
    png_structp  png  = NULL;
    png_infop    info = NULL;
    png_bytep   *rows = NULL;
    pdl         *pu   = NULL;
    pdl         *pf   = NULL;
    PngErrCtx    ctx;

    fp = fopen(filename, "rb");
    if (!fp) croak("rpng: cannot open '%s': %s", filename, strerror(errno));

    png = png_create_read_struct(PNG_LIBPNG_VER_STRING, &ctx,
                                 png_error_fn, png_warn_fn);
    if (!png) { fclose(fp); croak("rpng: png_create_read_struct failed"); }

    info = png_create_info_struct(png);
    if (!info) {
        png_destroy_read_struct(&png, NULL, NULL);
        fclose(fp);
        croak("rpng: png_create_info_struct failed");
    }

    if (setjmp(ctx.jmpbuf)) {
        png_destroy_read_struct(&png, &info, NULL);
        if (rows) free(rows);
        if (pu)   PDL->destroy(pu);
        fclose(fp);
        croak("rpng: libpng error: %s", ctx.msg);
    }

    png_init_io(png, fp);
    png_read_info(png, info);

    int W          = (int)png_get_image_width(png, info);
    int H          = (int)png_get_image_height(png, info);
    int color_type = png_get_color_type(png, info);
    int bit_depth  = png_get_bit_depth(png, info);

    if (color_type == PNG_COLOR_TYPE_PALETTE)
        png_set_palette_to_rgb(png);
    if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8)
        png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS))
        png_set_tRNS_to_alpha(png);
    if (bit_depth == 16)
        png_set_strip_16(png);
    if (color_type & PNG_COLOR_MASK_ALPHA)
        png_set_strip_alpha(png);
    if (color_type == PNG_COLOR_TYPE_GRAY ||
        color_type == PNG_COLOR_TYPE_GRAY_ALPHA)
        png_set_gray_to_rgb(png);

    png_read_update_info(png, info);

    /* Allocate uint8 PDL [C=3, W, H] */
    PDL_Indx udims[3] = {3, W, H};
    pu = PDL->pdlnew();
    if (!pu) { png_destroy_read_struct(&png,&info,NULL); fclose(fp);
               croak("rpng: pdlnew failed"); }
    PDL->setdims(pu, udims, 3);
    pu->datatype = PDL_B;
    PDL->allocdata(pu);

    unsigned char *ubuf = (unsigned char *)pu->data;
    if (!ubuf) { PDL->destroy(pu); png_destroy_read_struct(&png,&info,NULL);
                 fclose(fp); croak("rpng: allocdata returned NULL"); }

    rows = (png_bytep *)malloc(H * sizeof(png_bytep));
    if (!rows) { PDL->destroy(pu); png_destroy_read_struct(&png,&info,NULL);
                 fclose(fp); croak("rpng: out of memory for rows"); }

    for (int y = 0; y < H; y++)
        rows[y] = ubuf + (size_t)y * W * 3;

    png_read_image(png, rows);
    free(rows); rows = NULL;
    png_destroy_read_struct(&png, &info, NULL);
    fclose(fp);

    /* Allocate float32 PDL */
    PDL_Indx fdims[3] = {3, W, H};
    pf = PDL->pdlnew();
    if (!pf) { PDL->destroy(pu); croak("rpng: pdlnew (float) failed"); }
    PDL->setdims(pf, fdims, 3);
    pf->datatype = PDL_F;
    PDL->allocdata(pf);

    float *fbuf = (float *)pf->data;
    int n = H * W * 3;
    for (int i = 0; i < n; i++)
        fbuf[i] = ubuf[i] * (1.0f / 255.0f);

    PDL->destroy(pu);

    /* SetSV_PDL正しくpdlとSVを紐付ける（pf->svも設定される） */
    SV *ret = sv_newmortal();
    PDL->SetSV_PDL(ret, pf);
    SvREFCNT_inc(ret);   /* mortalなのでcallerに渡す前にrefcnt増やす */
    return ret;
}

/* ------------------------------------------------------------------ */
/* wpng - PDLポインタをパラメータで受け取る                             */
/* ------------------------------------------------------------------ */
void pdl_wpng(pdl *p, char *filename, Core *PDL) {
    FILE        *fp   = NULL;
    png_structp  png  = NULL;
    png_infop    info = NULL;
    png_bytep   *rows = NULL;
    unsigned char *buf = NULL;
    PngErrCtx    ctx;

    /* 基本チェック */
    if (!p) croak("wpng: NULL pdl pointer");
    if (p->ndims != 3)
        croak("wpng: input must have 3 dims, got %d", (int)p->ndims);
    if (p->dims[0] != 3)
        croak("wpng: dim(0) must be 3 (C), got %d", (int)p->dims[0]);

    /* float型に変換（必要なら） */
    pdl *pf = PDL->get_convertedpdl(p, PDL_F);
    if (!pf) croak("wpng: type conversion failed");
    PDL->make_physical(pf);
    if (!pf->data) croak("wpng: no data after make_physical");

    int W = (int)pf->dims[1];
    int H = (int)pf->dims[2];
    int n = H * W * 3;

    fp = fopen(filename, "wb");
    if (!fp) croak("wpng: cannot open '%s': %s", filename, strerror(errno));

    png = png_create_write_struct(PNG_LIBPNG_VER_STRING, &ctx,
                                  png_error_fn, png_warn_fn);
    if (!png) { fclose(fp); croak("wpng: png_create_write_struct failed"); }

    info = png_create_info_struct(png);
    if (!info) {
        png_destroy_write_struct(&png, NULL);
        fclose(fp);
        croak("wpng: png_create_info_struct failed");
    }

    if (setjmp(ctx.jmpbuf)) {
        png_destroy_write_struct(&png, &info);
        if (rows) free(rows);
        if (buf)  free(buf);
        fclose(fp);
        croak("wpng: libpng error: %s", ctx.msg);
    }

    png_init_io(png, fp);
    png_set_IHDR(png, info, (png_uint_32)W, (png_uint_32)H, 8,
                 PNG_COLOR_TYPE_RGB,
                 PNG_INTERLACE_NONE,
                 PNG_COMPRESSION_TYPE_DEFAULT,
                 PNG_FILTER_TYPE_DEFAULT);
    png_set_compression_level(png, 1);
    png_set_filter(png, 0, PNG_FILTER_NONE);
    png_write_info(png, info);

    buf = (unsigned char *)malloc((size_t)n);
    if (!buf) {
        png_destroy_write_struct(&png, &info);
        fclose(fp);
        croak("wpng: out of memory");
    }

    float *src = (float *)pf->data;
    for (int i = 0; i < n; i++) {
        float v = src[i] * 255.0f + 0.5f;
        if (v < 0.0f)   v = 0.0f;
        if (v > 255.0f) v = 255.0f;
        buf[i] = (unsigned char)v;
    }

    rows = (png_bytep *)malloc(H * sizeof(png_bytep));
    if (!rows) {
        free(buf);
        png_destroy_write_struct(&png, &info);
        fclose(fp);
        croak("wpng: out of memory for rows");
    }
    for (int y = 0; y < H; y++)
        rows[y] = buf + (size_t)y * W * 3;

    png_write_image(png, rows);
    png_write_end(png, NULL);

    free(rows);
    free(buf);
    png_destroy_write_struct(&png, &info);
    fclose(fp);

    /* pf が p と別物なら解放 */
    if (pf != p) PDL->destroy(pf);
}

/* ------------------------------------------------------------------ */
/* rpnga - RGBA版: [C=4, W, H] float32 を返す                         */
/*   dim0=0:R, 1:G, 2:B, 3:A  (アルファを捨てない)                    */
/* ------------------------------------------------------------------ */
SV *pdl_rpnga(char *filename, Core *PDL) {
    FILE        *fp   = NULL;
    png_structp  png  = NULL;
    png_infop    info = NULL;
    png_bytep   *rows = NULL;
    pdl         *pu   = NULL;
    pdl         *pf   = NULL;
    PngErrCtx    ctx;

    fp = fopen(filename, "rb");
    if (!fp) croak("rpnga: cannot open '%s': %s", filename, strerror(errno));

    png = png_create_read_struct(PNG_LIBPNG_VER_STRING, &ctx,
                                 png_error_fn, png_warn_fn);
    if (!png) { fclose(fp); croak("rpnga: png_create_read_struct failed"); }

    info = png_create_info_struct(png);
    if (!info) {
        png_destroy_read_struct(&png, NULL, NULL);
        fclose(fp);
        croak("rpnga: png_create_info_struct failed");
    }

    if (setjmp(ctx.jmpbuf)) {
        png_destroy_read_struct(&png, &info, NULL);
        if (rows) free(rows);
        if (pu)   PDL->destroy(pu);
        fclose(fp);
        croak("rpnga: libpng error: %s", ctx.msg);
    }

    png_init_io(png, fp);
    png_read_info(png, info);

    int W          = (int)png_get_image_width(png, info);
    int H          = (int)png_get_image_height(png, info);
    int color_type = png_get_color_type(png, info);
    int bit_depth  = png_get_bit_depth(png, info);

    /* Normalize to 8-bit RGBA */
    if (color_type == PNG_COLOR_TYPE_PALETTE)
        png_set_palette_to_rgb(png);
    if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8)
        png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS))
        png_set_tRNS_to_alpha(png);
    if (bit_depth == 16)
        png_set_strip_16(png);
    /* アルファがなければ追加 */
    if (!(color_type & PNG_COLOR_MASK_ALPHA))
        png_set_add_alpha(png, 255, PNG_FILLER_AFTER);
    /* グレーをRGBに */
    if (color_type == PNG_COLOR_TYPE_GRAY ||
        color_type == PNG_COLOR_TYPE_GRAY_ALPHA)
        png_set_gray_to_rgb(png);

    png_read_update_info(png, info);

    /* Allocate uint8 PDL [C=4, W, H] */
    PDL_Indx udims[3] = {4, W, H};
    pu = PDL->pdlnew();
    if (!pu) { png_destroy_read_struct(&png,&info,NULL); fclose(fp);
               croak("rpnga: pdlnew failed"); }
    PDL->setdims(pu, udims, 3);
    pu->datatype = PDL_B;
    PDL->allocdata(pu);

    unsigned char *ubuf = (unsigned char *)pu->data;
    if (!ubuf) { PDL->destroy(pu); png_destroy_read_struct(&png,&info,NULL);
                 fclose(fp); croak("rpnga: allocdata returned NULL"); }

    rows = (png_bytep *)malloc(H * sizeof(png_bytep));
    if (!rows) { PDL->destroy(pu); png_destroy_read_struct(&png,&info,NULL);
                 fclose(fp); croak("rpnga: out of memory"); }

    for (int y = 0; y < H; y++)
        rows[y] = ubuf + (size_t)y * W * 4;

    png_read_image(png, rows);
    free(rows); rows = NULL;
    png_destroy_read_struct(&png, &info, NULL);
    fclose(fp);

    /* float32変換 */
    PDL_Indx fdims[3] = {4, W, H};
    pf = PDL->pdlnew();
    if (!pf) { PDL->destroy(pu); croak("rpnga: pdlnew (float) failed"); }
    PDL->setdims(pf, fdims, 3);
    pf->datatype = PDL_F;
    PDL->allocdata(pf);

    float *fbuf = (float *)pf->data;
    int n = H * W * 4;
    for (int i = 0; i < n; i++)
        fbuf[i] = ubuf[i] * (1.0f / 255.0f);

    PDL->destroy(pu);

    SV *ret = sv_newmortal();
    PDL->SetSV_PDL(ret, pf);
    SvREFCNT_inc(ret);
    return ret;
}

/* ------------------------------------------------------------------ */
/* png_encode - byte [C, W, H] (C = 3 or 4) -> PNG bytes in a Perl SV */
/*   bgr   : input order is B,G,R(,A)  (png_set_bgr)                  */
/*   alpha : for C=4, 1 = write RGBA, 0 = drop 4th byte, write RGB    */
/*   level : zlib compression level 0..9                              */
/* ------------------------------------------------------------------ */
typedef struct {
    SV *out;
} PngMemDst;

static void png_mem_write_fn(png_structp png, png_bytep data, png_size_t len) {
    PngMemDst *dst = (PngMemDst *)png_get_io_ptr(png);
    dTHX;
    sv_catpvn(dst->out, (const char *)data, (STRLEN)len);
}

static void png_mem_flush_fn(png_structp png) {
    (void)png;
}

SV *pdl_png_encode(pdl *p, int bgr, int alpha, int level, Core *PDL) {
    png_structp  png  = NULL;
    png_infop    info = NULL;
    png_bytep   *rows = NULL;
    SV          *out  = NULL;
    PngErrCtx    ctx;
    PngMemDst    dst;

    if (!p) croak("png_encode: NULL pdl pointer");
    if (p->datatype != PDL_B)
        croak("png_encode: input must be of type byte");
    if (p->ndims != 3)
        croak("png_encode: input must have 3 dims (C, W, H), got %d",
              (int)p->ndims);

    int C = (int)p->dims[0];
    int W = (int)p->dims[1];
    int H = (int)p->dims[2];
    if (C != 3 && C != 4)
        croak("png_encode: dim(0) must be 3 or 4 (C), got %d", C);
    if (W < 1 || H < 1)
        croak("png_encode: image must be at least 1x1, got %dx%d", W, H);
    if (level < 0 || level > 9)
        croak("png_encode: level must be 0..9, got %d", level);
    if (alpha && C != 4)
        croak("png_encode: alpha => 1 needs 4 channels, got %d", C);

    /* slices etc. -> contiguous data */
    PDL->make_physical(p);
    if (!p->data) croak("png_encode: no data after make_physical");
    unsigned char *src = (unsigned char *)p->data;

    size_t rowbytes = (size_t)W * C;
    rows = (png_bytep *)malloc((size_t)H * sizeof(png_bytep));
    if (!rows) croak("png_encode: out of memory for rows");
    for (int y = 0; y < H; y++)
        rows[y] = src + (size_t)y * rowbytes;

    out = newSVpvn("", 0);
    SvGROW(out, rowbytes * H / 4 + 4096);
    dst.out = out;

    png = png_create_write_struct(PNG_LIBPNG_VER_STRING, &ctx,
                                  png_error_fn, png_warn_fn);
    if (!png) {
        free(rows); SvREFCNT_dec(out);
        croak("png_encode: png_create_write_struct failed");
    }
    info = png_create_info_struct(png);
    if (!info) {
        png_destroy_write_struct(&png, NULL);
        free(rows); SvREFCNT_dec(out);
        croak("png_encode: png_create_info_struct failed");
    }

    if (setjmp(ctx.jmpbuf)) {
        png_destroy_write_struct(&png, &info);
        free(rows);
        SvREFCNT_dec(out);
        croak("png_encode: libpng error: %s", ctx.msg);
    }

    png_set_write_fn(png, &dst, png_mem_write_fn, png_mem_flush_fn);
    png_set_IHDR(png, info, (png_uint_32)W, (png_uint_32)H, 8,
                 (C == 4 && alpha) ? PNG_COLOR_TYPE_RGB_ALPHA
                                   : PNG_COLOR_TYPE_RGB,
                 PNG_INTERLACE_NONE,
                 PNG_COMPRESSION_TYPE_DEFAULT,
                 PNG_FILTER_TYPE_DEFAULT);
    png_set_compression_level(png, level);
    png_set_filter(png, 0, PNG_FILTER_NONE);
    png_write_info(png, info);

    /* transforms: set after png_write_info (filler uses the IHDR color type) */
    if (bgr)
        png_set_bgr(png);
    if (C == 4 && !alpha)
        png_set_filler(png, 0, PNG_FILLER_AFTER);

    /* libpng copies each row before transforming; input is not modified */
    png_write_image(png, rows);
    png_write_end(png, NULL);

    png_destroy_write_struct(&png, &info);
    free(rows);
    return out;
}

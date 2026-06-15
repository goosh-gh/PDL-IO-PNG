# PDL::IO::PNG

Fast PNG image I/O for PDL via libpng — no FreeImage, no GD, no netpbm.

## Synopsis

```perl
use PDL;
use PDL::IO::PNG qw(rpng wpng rpnga);

# Read PNG → [H, W, 3] float32 ndarray, row=0 at top (upper-origin)
my $img = rpng('photo.png');
printf "dims: %s\n", join('x', $img->dims);  # e.g. 3x632x374 (internal [C,W,H])

# Write [H, W, 3] float32 ndarray → PNG
wpng($img, 'output.png');

# Read RGBA PNG → [H, W, 4] float32 (keeps alpha channel)
my $rgba = rpnga('drawing.png');
my $alpha = $rgba->slice("(3),:,:");   # alpha channel [W, H]
my $mask  = ($alpha > 0.5)->byte;      # binary mask from alpha
```

## Functions

### rpng

Read a PNG file → `[C=3, W, H]` float32 ndarray, values 0.0–1.0, row=0 at top.
All input formats (grey, palette, RGB, RGBA) are normalised to RGB.

### rpnga

Read a PNG file → `[C=4, W, H]` float32 ndarray, **preserving the alpha channel**.
Useful when the image encodes shape information in alpha rather than RGB
(common with macOS drawings where RGB=0,0,0 throughout and only alpha varies).

```perl
my $img  = rpnga('mask.png');
my $alpha = $img->slice("(3),:,:");   # [W, H]
my $fg    = ($alpha > 0.5)->byte;     # foreground mask
```

> **Tip**: If `rpng` returns all zeros, check with `sips -g all file.png`.
> `hasAlpha: yes` with RGB=0 means shape data is in the alpha channel — use `rpnga`.

### wpng

Write `[C=3, W, H]` float32 PDL ndarray to a PNG file. Values are clamped to 0.0–1.0.

As of v0.03, `wpng` uses **zlib compression level 1** (`PNG_FILTER_NONE`) instead of
the libpng default (level 6). This reduces write time from ~40 ms to ~5 ms on a
1100×900 image with no visible quality difference for scientific plots. File size
increases by roughly 20–30%.

## Features

- **Zero-copy read**: `png_read_image()` writes directly into the PDL data buffer
- **Output format**: `[C, W, H]` float32, values 0.0–1.0, row=0 at top (upper-origin)
- **Input formats**: grey (1/2/4/8-bit), palette, RGB, RGBA
- **Single dependency**: only `libpng`

## Benchmark (1000×1000 RGB PNG, Apple Silicon M-series)

### Read (rpng)

| Module | Speed | Notes |
|--------|-------|-------|
| **PDL::IO::PNG** | **2.5 ms** | libpng direct XS, this module |
| PDL::IO::Image | 5.3 ms (2.1× slower) | FreeImage via Alien::FreeImage |
| PDL::IO::Pic (rpic) | 18.9 ms (7.5× slower) | netpbm |
| Image::PNG::Libpng + manual PDL | 93.3 ms (37× slower) | no native PDL integration |

### Write (wpng, 1100×900, Apple Silicon M-series)

| Compression level | Speed | File size | Notes |
|------------------|-------|-----------|-------|
| 6 (libpng default) | ~40 ms | smaller | previous default |
| **1 + FILTER_NONE** | **~5 ms** | +20–30% | **current default (v0.03+)** |

## Installation

```bash
# MacPorts
sudo port install libpng
perl Makefile.PL && make && make test && make install

# Homebrew
brew install libpng
perl Makefile.PL && make && make test && make install

# apt (Ubuntu/Debian)
sudo apt install libpng-dev
perl Makefile.PL && make && make test && make install
```

## Axis convention

PDL stores arrays in column-major order. `rpng()` returns internal dims `[3, W, H]`,
which in user-facing (row-major) terms is `[H, W, 3]`:

```perl
my $H = $img->dim(0);   # height (but internally dim(2))
my $W = $img->dim(1);   # width
# $img->at(c, w, h)     # internal access
```

Row=0 is at the **top** of the image (upper-origin, PNG standard), compatible with
`PDL::Graphics::Cairo`'s `imshow()` default `origin => 'upper'`.

## Scope

PDL::IO::PNG is intentionally **PNG-only**. For other formats:

- JPEG, TIFF, BMP, GIF, WebP → [PDL::IO::Image](https://metacpan.org/pod/PDL::IO::Image) (FreeImage)
- JPEG, PNG via GD → [PDL::IO::GD](https://metacpan.org/pod/PDL::IO::GD)
- SVG, PDF output → [PDL::Graphics::Cairo](https://github.com/goosh-gh/PDL-Graphics-Cairo)

## See Also

- [PDL::IO::Image](https://metacpan.org/pod/PDL::IO::Image)
- [PDL::IO::Pic](https://metacpan.org/pod/PDL::IO::Pic)
- [Image::PNG::Libpng](https://metacpan.org/pod/Image::PNG::Libpng)

## Author

goosh-gh

## License

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

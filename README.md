# PDL::IO::PNG

Fast PNG image I/O for PDL via libpng — no FreeImage, no GD, no netpbm.

## Synopsis

```perl
use PDL;
use PDL::IO::PNG qw(rpng wpng);

# Read PNG → [H, W, 3] float32 ndarray, row=0 at top (upper-origin)
my $img = rpng('photo.png');
printf "dims: %s\n", join('x', $img->dims);  # e.g. 480x640x3

# Write [H, W, 3] float32 ndarray → PNG
wpng($img, 'output.png');
```

## Features

- **Zero-copy read**: `png_read_image()` writes directly into the PDL data buffer
- **Output format**: `[H, W, 3]` float32, values 0.0–1.0, row=0 at top (upper-origin)
- **Input formats**: grey (1/2/4/8-bit), palette, RGB, RGBA — all normalised to RGB float32
- **Single dependency**: only `libpng`

## Benchmark (1000×1000 RGB PNG, Apple Silicon M-series)

| Module | Speed | Notes |
|--------|-------|-------|
| **PDL::IO::PNG** | **2.5 ms** | libpng direct XS, this module |
| PDL::IO::Image | 5.3 ms (2.1× slower) | FreeImage via Alien::FreeImage |
| PDL::IO::Pic (rpic) | 18.9 ms (7.5× slower) | netpbm |
| Image::PNG::Libpng + manual PDL | 93.3 ms (37× slower) | no native PDL integration |

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

PDL stores arrays in column-major order, so the ndarray returned by `rpng()`
has internal dims `[3, W, H]`. In user-facing (row-major) terms this is `[H, W, 3]`:

```perl
my $H = $img->dim(0);   # height
my $W = $img->dim(1);   # width
# $img->at(h, w, c)     # pixel access
```

Row=0 is at the **top** of the image (upper-origin, PNG standard), so `imshow()`
in PDL::Graphics::Cairo works correctly with the default `origin => 'upper'`.

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

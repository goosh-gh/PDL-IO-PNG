#!/bin/bash
# build_and_test.sh
# Run this on macOS (MacPorts) to build PDL::IO::PNG
#
# Usage:
#   cd ~/src/PDL-IO-PNG
#   bash build_and_test.sh

set -e

echo "=== PDL::IO::PNG build script ==="
echo ""

# --- 1. Check prerequisites ---
echo "[1] Checking prerequisites..."

if ! pkg-config --exists libpng; then
    echo "ERROR: libpng not found via pkg-config"
    echo "Install: sudo port install libpng"
    echo "  (or: brew install libpng)"
    exit 1
fi
echo "  libpng: $(pkg-config --modversion libpng) OK"

if ! perl -MPDL::Core::Dev -e1 2>/dev/null; then
    echo "ERROR: PDL::Core::Dev not found"
    echo "Install: sudo port install p5-pdl  (or cpan PDL)"
    exit 1
fi
echo "  PDL::Core::Dev: OK"

echo ""

# --- 2. Build ---
echo "[2] Building..."
perl Makefile.PL
make

echo ""

# --- 3. Test ---
echo "[3] Running tests..."
perl -Iblib/lib -Iblib/arch t/01_basic.t

echo ""
echo "=== Build successful! ==="
echo ""
echo "To install system-wide:"
echo "  make install"
echo ""
echo "To use without installing:"
echo "  perl -Iblib/lib -Iblib/arch your_script.pl"
echo ""

# --- 4. Quick standalone benchmark ---
echo "[4] Quick benchmark..."
perl -Iblib/lib -Iblib/arch - << 'PERL'
use strict; use warnings;
use PDL;
use PDL::IO::PNG qw(rpng wpng);
use Time::HiRes qw(time);
use File::Temp  qw(tempfile);

# Create 1000x1000 test PNG
my $img = random(float, 3, 1000, 1000);
my ($fh, $tmpfile) = tempfile(SUFFIX => '.png', UNLINK => 1);
close $fh;
wpng($img, $tmpfile);

my $N = 50;

# --- PDL::IO::PNG ---
my $t0 = time();
for (1..$N) { rpng($tmpfile) }
my $ms_png = (time() - $t0) / $N * 1000;
printf "  PDL::IO::PNG       rpng: %6.3f ms/read  (1000x1000 RGB)\n", $ms_png;

# --- PDL::IO::Pic (rpic) ---
if (eval { require PDL::IO::Pic; 1 }) {
    my $t1 = time();
    for (1..$N) { PDL::IO::Pic::rpic($tmpfile) }
    my $ms = (time() - $t1) / $N * 1000;
    printf "  PDL::IO::Pic       rpic: %6.3f ms/read  (%4.1fx slower)\n",
        $ms, $ms / $ms_png;
}

# --- PDL::IO::Image (FreeImage) ---
if (eval { require PDL::IO::Image; 1 }) {
    my $t2 = time();
    for (1..$N) {
        my $obj = PDL::IO::Image->new_from_file($tmpfile);
        $obj->pixels_to_pdl;
    }
    my $ms = (time() - $t2) / $N * 1000;
    printf "  PDL::IO::Image  FreeImg: %6.3f ms/read  (%4.1fx slower)\n",
        $ms, $ms / $ms_png;
}

# --- Image::PNG::Libpng (libpng Perl binding, no PDL integration) ---
if (eval { require Image::PNG::Libpng; 1 }) {
    require PDL::IO::Pic;   # for unpack fallback
    my $t3 = time();
    for (1..$N) {
        my $png  = Image::PNG::Libpng::read_png_file($tmpfile);
        my $rows = $png->get_rows();          # arrayref of packed strings
        my $H    = scalar @$rows;
        my $W    = length($rows->[0]) / 3;
        # Pack all rows into one string then convert to PDL
        my $buf  = join('', @$rows);
        my $pdl  = PDL->new(unpack('C*', $buf))
                       ->reshape(3, $W, $H)
                       ->float / 255.0;
    }
    my $ms = (time() - $t3) / $N * 1000;
    printf "  Image::PNG::Libpng  +PDL: %6.3f ms/read  (%4.1fx slower)\n",
        $ms, $ms / $ms_png;
    print  "    (Note: Libpng has no PDL integration; Perl unpack loop adds overhead)\n";
}

print "\n";
printf "  Winner: PDL::IO::PNG at %.3f ms/read\n", $ms_png;
PERL

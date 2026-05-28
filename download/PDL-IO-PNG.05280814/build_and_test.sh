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
# Use blib so we test the freshly built version
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

# Create test image
my $img = random(float, 3, 1000, 1000);
my ($fh, $tmpfile) = tempfile(SUFFIX => '.png', UNLINK => 1);
close $fh;
wpng($img, $tmpfile);

my $N = 50;
my $t0 = time();
for (1..$N) { rpng($tmpfile) }
my $ms = (time() - $t0) / $N * 1000;
printf "  PDL::IO::PNG  rpng: %.3f ms/read  (1000x1000 RGB)\n", $ms;

# Compare with rpic if available
if (eval { require PDL::IO::Pic; 1 }) {
    my $t1 = time();
    for (1..$N) { PDL::IO::Pic::rpic($tmpfile) }
    my $ms2 = (time() - $t1) / $N * 1000;
    printf "  PDL::IO::Pic  rpic: %.3f ms/read\n", $ms2;
    printf "  Speedup: %.1fx\n", $ms2 / $ms;
}

# Compare with PDL::IO::Image if available
if (eval { require PDL::IO::Image; 1 }) {
    my $t2 = time();
    for (1..$N) {
        my $obj = PDL::IO::Image->new_from_file($tmpfile);
        $obj->pixels_to_pdl;
    }
    my $ms3 = (time() - $t2) / $N * 1000;
    printf "  PDL::IO::Image:     %.3f ms/read\n", $ms3;
    printf "  Speedup vs FreeImage: %.1fx\n", $ms3 / $ms;
}
PERL

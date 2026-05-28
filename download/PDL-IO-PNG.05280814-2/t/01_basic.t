#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use PDL;
use PDL::IO::PNG qw(rpng wpng);
use File::Temp qw(tempfile);
use Time::HiRes qw(time);

# ------------------------------------------------------------------ #
# 1. Basic round-trip: write then read                                #
# ------------------------------------------------------------------ #
subtest 'round-trip' => sub {
    # Build a simple [H=4, W=6, 3] test image (PDL internal: [3,6,4])
    my $orig = sequence(3, 6, 4)->float / (3*6*4 - 1);

    my ($fh, $tmpfile) = tempfile(SUFFIX => '.png', UNLINK => 1);
    close $fh;

    wpng($orig, $tmpfile);
    ok(-s $tmpfile > 0, "wpng: file created and non-empty");

    my $back = rpng($tmpfile);
    isa_ok($back, 'PDL', "rpng returns PDL");
    is($back->type, PDL::float(), "rpng returns float32");
    is_deeply([$back->dims], [3, 6, 4], "dims preserved [C,W,H]=[3,6,4]");

    # Values should round-trip to within 1/255
    my $diff = abs($back - $orig)->max->sclr;
    ok($diff < 1/255 + 1e-6, "round-trip pixel error < 1/255 (got $diff)");
};

# ------------------------------------------------------------------ #
# 2. Upper-origin check: top-left pixel                               #
# ------------------------------------------------------------------ #
subtest 'upper-origin' => sub {
    # Create 2×2 image:  red   green
    #                    blue  white
    my $img = zeros(float, 3, 2, 2);
    # [C, W, H]: at(c, x, y)
    # top-left (x=0,y=0): red
    $img->set(0,0,0, 1.0); $img->set(1,0,0, 0.0); $img->set(2,0,0, 0.0);
    # top-right (x=1,y=0): green
    $img->set(0,1,0, 0.0); $img->set(1,1,0, 1.0); $img->set(2,1,0, 0.0);
    # bottom-left (x=0,y=1): blue
    $img->set(0,0,1, 0.0); $img->set(1,0,1, 0.0); $img->set(2,0,1, 1.0);
    # bottom-right (x=1,y=1): white
    $img->set(0,1,1, 1.0); $img->set(1,1,1, 1.0); $img->set(2,1,1, 1.0);

    my ($fh, $tmpfile) = tempfile(SUFFIX => '.png', UNLINK => 1);
    close $fh;
    wpng($img, $tmpfile);
    my $back = rpng($tmpfile);

    # top-left should still be red after round-trip
    my $r = $back->at(0,0,0);
    my $g = $back->at(1,0,0);
    my $b = $back->at(2,0,0);
    ok($r > 0.9 && $g < 0.1 && $b < 0.1, "top-left pixel is red (r=$r g=$g b=$b)");
    # top-right green
    $r = $back->at(0,1,0); $g = $back->at(1,1,0); $b = $back->at(2,1,0);
    ok($r < 0.1 && $g > 0.9 && $b < 0.1, "top-right pixel is green");
};

# ------------------------------------------------------------------ #
# 3. Benchmark vs rpic (if available)                                 #
# ------------------------------------------------------------------ #
subtest 'benchmark' => sub {
    # Write a 1000x1000 test PNG first
    my $big = (random(float, 3, 1000, 1000))->float;
    my ($fh, $bigfile) = tempfile(SUFFIX => '.png', UNLINK => 1);
    close $fh;
    wpng($big, $bigfile);

    my $N = 20;

    # Benchmark rpng
    my $t0 = time();
    for (1..$N) { my $x = rpng($bigfile); }
    my $t_rpng = (time() - $t0) / $N * 1000;
    printf "  rpng (PDL::IO::PNG):  %.3f ms/read\n", $t_rpng;

    # Benchmark PDL::IO::Pic rpic if available
    if (eval { require PDL::IO::Pic; 1 }) {
        my $t1 = time();
        for (1..$N) { my $x = PDL::IO::Pic::rpic($bigfile); }
        my $t_rpic = (time() - $t1) / $N * 1000;
        printf "  rpic (PDL::IO::Pic): %.3f ms/read\n", $t_rpic;
        printf "  speedup vs rpic:     %.1fx\n", $t_rpic / $t_rpng;
    }

    # Benchmark PDL::IO::Image if available
    if (eval { require PDL::IO::Image; 1 }) {
        my $t2 = time();
        for (1..$N) {
            my $img = PDL::IO::Image->new_from_file($bigfile);
            my $x   = $img->pixels_to_pdl;
        }
        my $t_freeimage = (time() - $t2) / $N * 1000;
        printf "  PDL::IO::Image:           %.3f ms/read\n", $t_freeimage;
        printf "  speedup vs FreeImage:     %.1fx\n", $t_freeimage / $t_rpng;
    }

    # Benchmark Image::PNG::Libpng if available
    if (eval { require Image::PNG::Libpng; 1 }) {
        my $t3 = time();
        for (1..$N) {
            my $png  = Image::PNG::Libpng::read_png_file($bigfile);
            my $rows = $png->get_rows();
            my $H    = scalar @$rows;
            my $W    = length($rows->[0]) / 3;
            my $buf  = join(\'\', @$rows);
            my $x    = PDL->new(unpack(\'C*\', $buf))
                           ->reshape(3, $W, $H)
                           ->float / 255.0;
        }
        my $t_libpng = (time() - $t3) / $N * 1000;
        printf "  Image::PNG::Libpng+PDL:   %.3f ms/read\n", $t_libpng;
        printf "  speedup vs Libpng+PDL:    %.1fx\n", $t_libpng / $t_rpng;
        print  "    (no PDL integration: Perl unpack loop overhead)\n";
    }

    ok($t_rpng < 10.0, "rpng faster than 10ms (got ${t_rpng}ms)");
};

# ------------------------------------------------------------------ #
# 4. Error handling                                                   #
# ------------------------------------------------------------------ #
subtest 'error handling' => sub {
    eval { rpng('/nonexistent/file.png') };
    like($@, qr/cannot open/, "rpng dies on missing file");

    my ($fh, $tmpfile) = tempfile(SUFFIX => '.png', UNLINK => 1);
    print $fh "not a png file\n";
    close $fh;
    eval { rpng($tmpfile) };
    ok($@, "rpng dies on corrupt file");

    # wpng with wrong dims
    my $bad = zeros(float, 4, 10, 10);  # C=4, not 3
    my ($fh2, $tmp2) = tempfile(SUFFIX => '.png', UNLINK => 1);
    close $fh2;
    eval { wpng($bad, $tmp2) };
    like($@, qr/must be/, "wpng dies on wrong channel count");
};

done_testing();

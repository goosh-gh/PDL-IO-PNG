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
    my $orig = sequence(3, 6, 4)->float / (3*6*4 - 1);

    my ($fh, $tmpfile) = tempfile(SUFFIX => '.png', UNLINK => 1);
    close $fh;

    wpng($orig, $tmpfile);
    ok(-s $tmpfile > 0, "wpng: file created and non-empty");

    my $back = rpng($tmpfile);
    isa_ok($back, 'PDL', "rpng returns PDL");
    is($back->type, PDL::float(), "rpng returns float32");
    is_deeply([$back->dims], [3, 6, 4], "dims preserved [C,W,H]=[3,6,4]");

    my $diff = abs($back - $orig)->max->sclr;
    ok($diff < 1/255 + 1e-6, "round-trip pixel error < 1/255 (got $diff)");
};

# ------------------------------------------------------------------ #
# 2. Upper-origin check                                               #
# ------------------------------------------------------------------ #
subtest 'upper-origin' => sub {
    my $img = zeros(float, 3, 2, 2);
    # top-left (x=0,y=0): red
    $img->set(0,0,0, 1.0); $img->set(1,0,0, 0.0); $img->set(2,0,0, 0.0);
    # top-right (x=1,y=0): green
    $img->set(0,1,0, 0.0); $img->set(1,1,0, 1.0); $img->set(2,1,0, 0.0);

    my ($fh, $tmpfile) = tempfile(SUFFIX => '.png', UNLINK => 1);
    close $fh;
    wpng($img, $tmpfile);
    my $back = rpng($tmpfile);

    my $r = $back->at(0,0,0);
    my $g = $back->at(1,0,0);
    my $b = $back->at(2,0,0);
    ok($r > 0.9 && $g < 0.1 && $b < 0.1, "top-left pixel is red (r=$r g=$g b=$b)");
    $r = $back->at(0,1,0); $g = $back->at(1,1,0); $b = $back->at(2,1,0);
    ok($r < 0.1 && $g > 0.9 && $b < 0.1, "top-right pixel is green");
};

# ------------------------------------------------------------------ #
# 3. Benchmark                                                        #
# ------------------------------------------------------------------ #
subtest 'benchmark' => sub {
    my $big = random(float, 3, 1000, 1000);
    my ($fh, $bigfile) = tempfile(SUFFIX => '.png', UNLINK => 1);
    close $fh;
    wpng($big, $bigfile);

    my $N = 20;

    # PDL::IO::PNG
    my $t0 = time();
    for (1..$N) { rpng($bigfile) }
    my $t_rpng = (time() - $t0) / $N * 1000;
    printf "  PDL::IO::PNG       rpng: %6.3f ms/read\n", $t_rpng;

    # PDL::IO::Pic rpic
    if (eval { require PDL::IO::Pic; 1 }) {
        my $t1 = time();
        for (1..$N) { PDL::IO::Pic::rpic($bigfile) }
        my $ms = (time() - $t1) / $N * 1000;
        printf "  PDL::IO::Pic       rpic: %6.3f ms/read  (%4.1fx slower)\n",
            $ms, $ms / $t_rpng;
    }

    # PDL::IO::Image
    if (eval { require PDL::IO::Image; 1 }) {
        my $t2 = time();
        for (1..$N) {
            my $img = PDL::IO::Image->new_from_file($bigfile);
            $img->pixels_to_pdl;
        }
        my $ms = (time() - $t2) / $N * 1000;
        printf "  PDL::IO::Image  FreeImg: %6.3f ms/read  (%4.1fx slower)\n",
            $ms, $ms / $t_rpng;
    }

    # Image::PNG::Libpng
    if (eval { require Image::PNG::Libpng; 1 }) {
        my $t3 = time();
        for (1..$N) {
            my $png  = Image::PNG::Libpng::read_png_file($bigfile);
            my $rows = $png->get_rows();
            my $H    = scalar @$rows;
            my $W    = length($rows->[0]) / 3;
            my $buf  = join('', @$rows);
            my $x    = PDL->new(unpack('C*', $buf))
                           ->reshape(3, $W, $H)
                           ->float / 255.0;
        }
        my $ms = (time() - $t3) / $N * 1000;
        printf "  Image::PNG::Libpng +PDL: %6.3f ms/read  (%4.1fx slower)\n",
            $ms, $ms / $t_rpng;
        print  "    (no native PDL integration: Perl unpack loop overhead)\n";
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

    my ($fh2, $tmp2) = tempfile(SUFFIX => '.png', UNLINK => 1);
    close $fh2;
    my $bad = zeros(float, 4, 10, 10);
    eval { wpng($bad, $tmp2) };
    like($@, qr/must/, "wpng dies on wrong channel count");
};

done_testing();

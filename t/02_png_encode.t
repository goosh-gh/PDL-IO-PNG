#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use PDL;
use PDL::IO::PNG qw(png_encode rpnga);
use File::Temp qw(tempfile);
use Compress::Zlib ();

# ------------------------------------------------------------------ #
# Independent decoders                                               #
# ------------------------------------------------------------------ #

# Minimal PNG reader written from the PNG specification (not from the
# encoder): signature, IHDR, concatenated IDAT, zlib inflate, one filter
# byte per row. Only filter type 0 (None) is accepted, since png_encode
# writes with PNG_FILTER_NONE. Returns (byte pdl [C,W,H], color_type).
sub spec_decode {
    my ($png) = @_;
    die "bad signature\n"
        unless substr($png, 0, 8) eq "\x89PNG\r\n\x1a\n";
    my $pos = 8;
    my ($W, $H, $depth, $ct, $idat, $seen_iend) = (0, 0, 0, 0, '', 0);
    while ($pos < length $png) {
        my ($len, $type) = unpack('N a4', substr($png, $pos, 8));
        my $data = substr($png, $pos + 8, $len);
        my $crc  = unpack('N', substr($png, $pos + 8 + $len, 4));
        die "CRC mismatch in $type\n"
            if $crc != Compress::Zlib::crc32($type . $data);
        if    ($type eq 'IHDR') { ($W, $H, $depth, $ct) = unpack('N N C C', $data) }
        elsif ($type eq 'IDAT') { $idat .= $data }
        elsif ($type eq 'IEND') { $seen_iend = 1 }
        $pos += 12 + $len;
    }
    die "no IEND\n" unless $seen_iend;
    die "bit depth $depth\n" unless $depth == 8;
    my $C = $ct == 2 ? 3 : $ct == 6 ? 4 : die "color type $ct\n";
    my $raw = Compress::Zlib::uncompress($idat);
    die "inflate failed\n" unless defined $raw;
    my $rb = $W * $C;
    die "raw size\n" unless length($raw) == $H * ($rb + 1);
    my $pix = '';
    for my $y (0 .. $H - 1) {
        my $f = ord substr($raw, $y * ($rb + 1), 1);
        die "filter type $f on row $y\n" unless $f == 0;
        $pix .= substr($raw, $y * ($rb + 1) + 1, $rb);
    }
    my $p = zeros(byte, $C, $W, $H);
    ${ $p->get_dataref } = $pix;
    $p->upd_data;
    return ($p, $ct);
}

# rpnga (libpng read path of this module) -> byte [4,W,H]
sub rpnga_decode {
    my ($png) = @_;
    my ($fh, $file) = tempfile(SUFFIX => '.png', UNLINK => 1);
    binmode $fh;
    print $fh $png;
    close $fh;
    return (rpnga($file) * 255 + 0.5)->byte;
}

my $have_cairo = eval { require Cairo; 1 };

# Cairo (libpng via cairo) -> byte [4,W,H] in cairo's B,G,R,A memory order
sub cairo_decode {
    my ($png) = @_;
    my $off = 0;
    my $s = Cairo::ImageSurface->create_from_png_stream(sub {
        my (undef, $len) = @_;
        my $chunk = substr($png, $off, $len);
        $off += length $chunk;
        return $chunk;
    });
    die "cairo status " . $s->status . "\n" unless $s->status eq 'success';
    my ($W, $H, $stride) = ($s->get_width, $s->get_height, $s->get_stride);
    die "stride $stride\n" unless $stride == 4 * $W;
    my $p = zeros(byte, 4, $W, $H);
    ${ $p->get_dataref } = $s->get_data;
    $p->upd_data;
    return $p;
}

sub color_type { ord substr($_[0], 25, 1) }

# Synthetic image: W != H, W not a multiple of 4, every channel varies
# with x and y. Alpha (channel 3) is not constant.
my ($W, $H) = (37, 23);
my $c  = xvals(long, 4, $W, $H);
my $xx = yvals(long, 4, $W, $H);
my $yy = zvals(long, 4, $W, $H);
my $rgba = (($c * 61 + $xx * 7 + $yy * 13 + $xx * $yy * 3 + 5) % 256)->byte;
is_deeply([$rgba->dims], [4, $W, $H], 'fixture dims');
ok(($rgba->slice('(3)')->max - $rgba->slice('(3)')->min)->sclr > 100,
   'fixture alpha varies');

# Expected RGB from a B,G,R,A input, built independently by slicing
sub bgra_of { my $p = shift; $p->slice('2:0:-1')->append($p->slice('3')) }

# ------------------------------------------------------------------ #
subtest 'RGBA round-trip (all pixels, three decoders)' => sub {
    my $png = png_encode($rgba);              # C=4 -> alpha kept by default
    is(color_type($png), 6, 'color type 6 (RGBA)');

    my ($d, $ct) = spec_decode($png);
    is($ct, 6, 'spec decoder sees RGBA');
    is_deeply([$d->dims], [4, $W, $H], 'spec decoder dims');
    is((($d->long - $rgba->long)->abs->max)->sclr, 0, 'spec decoder: all pixels equal');

    my $r = rpnga_decode($png);
    is((($r->long - $rgba->long)->abs->max)->sclr, 0, 'rpnga: all pixels equal');
};

subtest 'alpha => 0 drops the 4th byte' => sub {
    my $png = png_encode($rgba, alpha => 0);
    is(color_type($png), 2, 'color type 2 (RGB)');
    my ($d) = spec_decode($png);
    is_deeply([$d->dims], [3, $W, $H], 'decoded dims [3,W,H]');
    is((($d->long - $rgba->slice('0:2')->long)->abs->max)->sclr, 0,
       'RGB equal to first three channels');
    ok(length($png) < length(png_encode($rgba)), 'RGB smaller than RGBA');
};

subtest 'C = 3 input' => sub {
    my $rgb = $rgba->slice('0:2')->copy;
    my $png = png_encode($rgb);
    is(color_type($png), 2, 'color type 2');
    my ($d) = spec_decode($png);
    is((($d->long - $rgb->long)->abs->max)->sclr, 0, 'all pixels equal');
    my $r = rpnga_decode($png);
    is((($r->slice('0:2')->long - $rgb->long)->abs->max)->sclr, 0, 'rpnga RGB equal');
    ok(all($r->slice('(3)') == 255), 'rpnga alpha all 255');
};

subtest 'bgr => 1' => sub {
    my $bgra = bgra_of($rgba)->copy;
    is_deeply([$bgra->dims], [4, $W, $H], 'B,G,R,A fixture dims');

    my ($d) = spec_decode(png_encode($bgra, bgr => 1));
    is((($d->long - $rgba->long)->abs->max)->sclr, 0, 'RGBA restored from B,G,R,A');

    my ($d3) = spec_decode(png_encode($bgra, bgr => 1, alpha => 0));
    is((($d3->long - $rgba->slice('0:2')->long)->abs->max)->sclr, 0,
       'bgr + alpha => 0: RGB restored');

    # negative control: without bgr, R and B come out swapped
    my ($n) = spec_decode(png_encode($bgra, alpha => 0));
    ok(any($n->slice('0') != $rgba->slice('0')), 'without bgr: R differs');
    is((($n->slice('0')->long - $rgba->slice('2')->long)->abs->max)->sclr, 0,
       'without bgr: R channel holds B');
};

subtest 'known colours through Cairo' => sub {
    plan skip_all => 'Cairo not installed' unless $have_cairo;
    my ($w, $h) = (30, 7);
    my $s  = Cairo::ImageSurface->create('argb32', $w, $h);
    my $cr = Cairo::Context->create($s);
    my @col = ([1, 0, 0], [0, 1, 0], [0, 0, 1]);
    for my $i (0 .. 2) {
        $cr->set_source_rgb(@{ $col[$i] });
        $cr->rectangle($i * 10, 0, 10, $h);
        $cr->fill;
    }
    $s->flush;
    is($s->get_stride, 4 * $w, 'stride == 4*W');
    my $bgra = zeros(byte, 4, $w, $h);
    ${ $bgra->get_dataref } = $s->get_data;
    $bgra->upd_data;

    my ($d) = spec_decode(png_encode($bgra, bgr => 1, alpha => 0));
    for my $i (0 .. 2) {
        my $xc = $i * 10 + 5;
        my $px = $d->slice(':', "($xc)", '(3)');
        my $want = pdl(byte, map { $_ * 255 } @{ $col[$i] });
        is_deeply([$px->list], [$want->list], "bgr: band $i is " . join(',', $want->list));
    }
    my ($n) = spec_decode(png_encode($bgra, alpha => 0));
    is_deeply([$n->slice(':', '(5)', '(3)')->list], [0, 0, 255],
              'negative control: without bgr, red band reads as blue');

    # decode with cairo too: back to the same B,G,R,A bytes
    my $back = cairo_decode(png_encode($bgra, bgr => 1, alpha => 0));
    is((($back->long - $bgra->long)->abs->max)->sclr, 0,
       'cairo decode equals the original surface bytes');
};

subtest 'opaque synthetic image through Cairo' => sub {
    plan skip_all => 'Cairo not installed' unless $have_cairo;
    my $op = $rgba->copy;
    $op->slice('3') .= 255;
    my $back = cairo_decode(png_encode($op));        # cairo: B,G,R,A
    is((($back->long - bgra_of($op)->long)->abs->max)->sclr, 0,
       'cairo decode (RGBA in) equals input');
    my $back2 = cairo_decode(png_encode(bgra_of($op)->copy, bgr => 1, alpha => 0));
    is((($back2->long - bgra_of($op)->long)->abs->max)->sclr, 0,
       'cairo decode (B,G,R,A in, bgr, alpha=>0) equals input');
};

subtest 'level' => sub {
    my $p0 = png_encode($rgba, level => 0);
    my $p1 = png_encode($rgba);
    my $p9 = png_encode($rgba, level => 9);
    my ($d0) = spec_decode($p0);
    my ($d9) = spec_decode($p9);
    is((($d0->long - $rgba->long)->abs->max)->sclr, 0, 'level 0 pixels equal');
    is((($d9->long - $rgba->long)->abs->max)->sclr, 0, 'level 9 pixels equal');
    ok(length($p0) > length($p1), 'level 0 larger than level 1 ('
       . length($p0) . ' > ' . length($p1) . ')');
    # stored (level 0) data: compressed size >= raw size
    ok(length($p0) >= $H * ($W * 4 + 1), 'level 0 is not compressed');
};

subtest 'input not modified, non-contiguous input' => sub {
    my $bgra = bgra_of($rgba)->copy;
    my $keep = $bgra->copy;
    png_encode($bgra, bgr => 1, alpha => 0);
    is((($bgra->long - $keep->long)->abs->max)->sclr, 0, 'input unchanged');

    my $sl = $rgba->slice('2:0:-1');                  # strided view
    my ($d) = spec_decode(png_encode($sl));
    is((($d->long - $rgba->slice('2:0:-1')->copy->long)->abs->max)->sclr, 0,
       'reversed-channel slice encodes its own values');
};

subtest '1x1 image' => sub {
    my $one = pdl(byte, [10, 20, 30])->reshape(3, 1, 1);
    my ($d) = spec_decode(png_encode($one));
    is_deeply([$d->list], [10, 20, 30], '1x1 RGB');
};

subtest 'errors' => sub {
    my %bad = (
        '2 dims'        => sub { png_encode(zeros(byte, 3, 4)) },
        'C = 2'         => sub { png_encode(zeros(byte, 2, 4, 4)) },
        'C = 5'         => sub { png_encode(zeros(byte, 5, 4, 4)) },
        'float input'   => sub { png_encode(zeros(float, 3, 4, 4)) },
        'not a pdl'     => sub { png_encode('abc') },
        'unknown opt'   => sub { png_encode(zeros(byte, 3, 4, 4), bgra => 1) },
        'level 10'      => sub { png_encode(zeros(byte, 3, 4, 4), level => 10) },
        'level -1'      => sub { png_encode(zeros(byte, 3, 4, 4), level => -1) },
        'alpha with C3' => sub { png_encode(zeros(byte, 3, 4, 4), alpha => 1) },
        'empty image'   => sub { png_encode(zeros(byte, 3, 0, 4)) },
    );
    for my $name (sort keys %bad) {
        eval { $bad{$name}->() };
        like($@, qr/png_encode/, "croaks: $name");
    }
    # positive control: valid call does not croak
    ok(eval { png_encode(zeros(byte, 3, 4, 4)); 1 }, 'valid call succeeds');
};

done_testing();

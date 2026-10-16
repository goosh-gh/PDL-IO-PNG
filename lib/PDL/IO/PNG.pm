package PDL::IO::PNG;

use strict;
use warnings;
use PDL::Core;
use Exporter 'import';
use Carp ();

our $VERSION   = '0.01';
our @EXPORT    = ();
our @EXPORT_OK = qw(rpng wpng rpnga png_encode);

# Load the XS compiled code
require XSLoader;
XSLoader::load('PDL::IO::PNG', $VERSION);

my %PNG_ENCODE_OPT = map { $_ => 1 } qw(bgr alpha level);

sub png_encode {
    my ($img, %opt) = @_;
    my @bad = grep { !$PNG_ENCODE_OPT{$_} } sort keys %opt;
    Carp::croak("png_encode: unknown option(s): @bad") if @bad;
    Carp::croak("png_encode: input must be a PDL ndarray")
        unless ref($img) && eval { $img->isa('PDL') };
    my $C = $img->getndims >= 1 ? $img->dim(0) : 0;
    my $bgr   = $opt{bgr}   ? 1 : 0;
    my $alpha = defined $opt{alpha} ? ($opt{alpha} ? 1 : 0)
                                    : ($C == 4 ? 1 : 0);
    my $level = defined $opt{level} ? $opt{level} : 1;
    Carp::croak("png_encode: level must be an integer 0..9, got '$level'")
        unless $level =~ /\A[0-9]\z/;
    my $png = eval { _png_encode($img, $bgr, $alpha, $level) };
    if (!defined $png) {
        (my $msg = $@) =~ s/ at \S+ line \d+\.?\n\z//;   # report at caller
        Carp::croak($msg);
    }
    return $png;
}

=head1 NAME

PDL::IO::PNG - Fast PNG image I/O for PDL via libpng

=head1 SYNOPSIS

    use PDL;
    use PDL::IO::PNG qw(rpng wpng);

    # Read PNG → [H, W, 3] float32 ndarray, row=0 at top (upper-origin)
    my $img = rpng('photo.png');
    printf "dims: %s\n", join('x', $img->dims);  # e.g. 480x640x3
    printf "type: %s\n", $img->type;             # Float

    # Write [H, W, 3] float32 ndarray → PNG
    wpng($img, 'output.png');

    # Works directly with PDL::Graphics::Cairo imshow():
    use PDL::Graphics::Cairo qw(figure);
    my $fig = figure(width => 800, height => 600);
    my $ax  = $fig->axes();
    $ax->imshow($img);    # origin=>'upper' default — correct
    $fig->tight_layout();
    $fig->show();

=head1 DESCRIPTION

C<PDL::IO::PNG> provides fast PNG image reading and writing for PDL,
using C<libpng> directly via XS — no heavy intermediate libraries.

=head2 Key properties

=over 4

=item * B<Zero-copy read>: C<png_read_image()> writes directly into the
PDL ndarray data buffer. One memcpy for uint8→float32 conversion, nothing more.

=item * B<Output format>: C<[H, W, 3]> float32 ndarray, values 0.0–1.0,
B<row=0 at top> (upper-origin, PNG standard). Compatible with
C<PDL::Graphics::Cairo>'s C<imshow()> default (C<origin =E<gt> 'upper'>).

=item * B<Input format>: Reads 1/2/4/8-bit grey, palette, RGB, RGBA PNG files.
All are normalised to 8-bit RGB float32 on output.

=item * B<Dependency>: Only C<libpng> (C<port install libpng> or C<brew install libpng>).
No FreeImage, no GD, no netpbm.

=back

=head2 Axis convention

In PDL's internal (column-major) representation the ndarray has
C<dims = [3, W, H]>. In user-facing (row-major) terms this is
C<[H, W, 3]>. Use C<$img-E<gt>dim(0)> for H, C<$img-E<gt>dim(1)> for W.

    my $H = $img->dim(0);
    my $W = $img->dim(1);

=head2 Comparison with alternatives

    Module                          Speed (1000x1000 RGB)    Dependencies
    PDL::IO::PNG                    ~2.5 ms  <- this         libpng only
    PDL::IO::Image (FreeImage)      ~5.3 ms  (2.1x slower)  Alien::FreeImage (heavy)
    PDL::IO::Pic (rpic)             ~18.9 ms (7.5x slower)  netpbm
    Image::PNG::Libpng + PDL        ~93 ms   (37x slower)   no native PDL integration

=head1 FUNCTIONS

=head2 rpng

    my $img = rpng($filename);

Read a PNG file and return a C<[H, W, 3]> float32 PDL ndarray.
Row=0 is the top of the image (upper-origin, matching PNG standard).

Dies on error.

=head2 wpng

    wpng($img, $filename);

Write a C<[H, W, 3]> float32 PDL ndarray to a PNG file.
Values should be in the range 0.0–1.0 (clamped automatically).

Dies on error.

=head1 INSTALLATION

    # MacPorts
    sudo port install libpng
    perl Makefile.PL && make && make test && make install

    # Homebrew
    brew install libpng
    perl Makefile.PL && make && make test && make install

=head2 rpnga

    my $img = rpnga($filename);

Read a PNG file and return a C<[H, W, 4]> float32 PDL ndarray (RGBA).
dim(2)=0:R, 1:G, 2:B, 3:A. Useful when the image encodes information
in the alpha channel (e.g. transparent drawings where RGB=0,0,0 throughout).

=head2 png_encode

    my $png = png_encode($bytes, %opt);

Encode a byte ndarray of dims C<[C, W, H]> (C = 3 or 4, row 0 at the top)
and return the PNG file contents as a Perl scalar. Nothing is written to
disk. The input is not modified; slices are accepted.

Options:

=over 4

=item C<bgr =E<gt> 1>

The input channel order is B, G, R(, A). This matches the memory layout
of a Cairo C<argb32> image surface on little-endian machines. Default 0
(R, G, B(, A)).

=item C<alpha =E<gt> 0|1>

For 4-channel input: 1 writes RGBA (color type 6), 0 drops the 4th byte
and writes RGB (color type 2). Default 1 for 4-channel input. 3-channel
input is always written as RGB; C<alpha =E<gt> 1> with 3 channels dies.

=item C<level =E<gt> 0..9>

zlib compression level. Default 1, the same as C<wpng>. Rows are written
with filter type None.

=back

The channel values are written as they are. Cairo surfaces store
premultiplied alpha; for a fully opaque surface the values are the same
either way.

    # Cairo argb32 surface -> PNG bytes (stride must be 4*W)
    my $p = zeros(byte, 4, $W, $H);
    ${ $p->get_dataref } = $surface->get_data;
    $p->upd_data;
    my $png = png_encode($p, bgr => 1, alpha => 0);

Dies if the input is not a byte ndarray with 3 dims, if C is not 3 or 4,
on an unknown option, or if C<level> is outside 0..9.

=head1 SEE ALSO

L<PDL::IO::Image>, L<PDL::IO::Pic>, L<PDL::Graphics::Cairo>

=head1 AUTHOR

goosh-gh

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;

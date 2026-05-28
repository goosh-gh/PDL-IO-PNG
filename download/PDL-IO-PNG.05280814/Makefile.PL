use strict;
use warnings;
use ExtUtils::MakeMaker;
use PDL::Core::Dev;

# --- libpng detection via pkg-config ---
my $png_cflags = `pkg-config --cflags libpng 2>/dev/null`; chomp $png_cflags;
my $png_libs   = `pkg-config --libs   libpng 2>/dev/null`; chomp $png_libs;

unless ($png_libs) {
    # Fallback: try libpng16 directly
    $png_cflags = '-I/usr/include/libpng16';
    $png_libs   = '-lpng16 -lz';
    warn "pkg-config libpng not found, using fallback: $png_libs\n";
}

print "libpng cflags: $png_cflags\n";
print "libpng libs:   $png_libs\n";

# PDL include path
my $pdl_inc = PDL_INCLUDE();  # e.g. -I/opt/local/lib/perl5/.../PDL/Core

WriteMakefile(
    NAME          => 'PDL::IO::PNG',
    VERSION_FROM  => 'lib/PDL/IO/PNG.pm',
    ABSTRACT_FROM => 'lib/PDL/IO/PNG.pm',
    AUTHOR        => 'goosh-gh',
    LICENSE       => 'perl',

    INC     => "$pdl_inc $png_cflags",
    LIBS    => [$png_libs],

    # Our C source + XS
    C       => ['pdl_png.c'],
    XS      => {'PNG.xs' => 'PNG.c'},
    OBJECT  => 'PNG$(OBJ_EXT) pdl_png$(OBJ_EXT)',

    # PDL requires this for pdlcore.h
    DEFINE  => '',

    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources   => {
            repository => {
                type => 'git',
                url  => 'https://github.com/goosh-gh/PDL-IO-PNG.git',
            },
        },
    },

    PREREQ_PM => {
        'PDL'  => '2.0',
    },
    TEST_REQUIRES => {
        'Test::More' => '0',
    },
);

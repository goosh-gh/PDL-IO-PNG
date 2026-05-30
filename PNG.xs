/* PNG.xs - XS glue for PDL::IO::PNG */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "pdl.h"
#include "pdlcore.h"

static Core *PDL = NULL;

/* Forward declarations - PDL core passed as parameter */
SV   *pdl_rpng(char *filename, Core *PDL_core);
void  pdl_wpng(pdl *p, char *filename, Core *PDL_core);
SV   *pdl_rpnga(char *filename, Core *PDL_core);

MODULE = PDL::IO::PNG   PACKAGE = PDL::IO::PNG

PROTOTYPES: DISABLE

BOOT:
   perl_require_pv("PDL/Core.pm");
#ifndef aTHX_
#define aTHX_
#endif
   if (SvTRUE(ERRSV)) Perl_croak(aTHX_ "%s", SvPV_nolen(ERRSV));
   {
     SV *CoreSV = perl_get_sv("PDL::SHARE", FALSE);
     if (!CoreSV)
       Perl_croak(aTHX_ "We require the PDL::Core module, which was not found");
     PDL = INT2PTR(Core*, SvIV(CoreSV));
     if (!PDL)
       Perl_croak(aTHX_ "Got NULL pointer for PDL");
     if (PDL->Version != PDL_CORE_VERSION)
       Perl_croak(aTHX_ "PDL::IO::PNG needs to be recompiled against the newly installed PDL");
   }

SV *
rpng(filename)
    char *filename
  CODE:
    RETVAL = pdl_rpng(filename, PDL);
  OUTPUT:
    RETVAL

void
wpng(pdl_sv, filename)
    SV   *pdl_sv
    char *filename
  PREINIT:
    pdl *p;
  CODE:
    p = PDL->SvPDLV(pdl_sv);
    if (!p) croak("wpng: failed to get PDL from argument");
    pdl_wpng(p, filename, PDL);

SV *
rpnga(filename)
    char *filename
  CODE:
    RETVAL = pdl_rpnga(filename, PDL);
  OUTPUT:
    RETVAL

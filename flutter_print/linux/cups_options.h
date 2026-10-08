#ifndef FLUTTER_PRINT_CUPS_OPTIONS_H_
#define FLUTTER_PRINT_CUPS_OPTIONS_H_

#include <cups/cups.h>
#include <cups/pwg.h>

#include "flutter_print_plugin_private.h"

// Returns the CUPS "sides" value for the duplex mode of |options|, or null
// when it is unset.
const char* duplex_sides(FlutterPrintPrintOptions* options);

// Returns the PWG paper for |page_size|. Uses the width and height when they
// are set, because CUPS doesn't know some names ("DL") and reads others in
// another way ("B4" is JIS B4 for CUPS). Else looks up the name ("A4",
// "Letter"). Returns null when nothing matches.
pwg_media_t* page_size_media(FlutterPrintPageSize* page_size);

// Returns the page ranges of |options| as a CUPS "page-ranges" value
// ("2-6,9"), or null when they are unset. Free it with g_free.
gchar* build_page_ranges(FlutterPrintPrintOptions* options);

// Returns the ColorModel choice of the |printer| driver for colour or mono,
// or null when the driver has none. Names vary by driver ("Gray",
// "grayscale", "RGB"…). Free it with g_free.
gchar* color_model_choice(const char* printer, bool color);

#endif  // FLUTTER_PRINT_CUPS_OPTIONS_H_

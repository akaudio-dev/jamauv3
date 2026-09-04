// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov
//
// Single translation unit that compiles the stb_vorbis implementation.
// Vendored from nothings/stb (stb_vorbis.c v1.22, public domain).
// Everything else imports the CStbVorbis module for the declarations.
//
// We feed OGG bytes off the network via the pushdata API, so the file/stdio API
// is disabled (STB_VORBIS_NO_STDIO). Pushdata stays enabled (it is the default).
// The integer-conversion API is never called from Swift (we use the float pushdata
// path only), so disable it too — less code compiled against untrusted input.
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_INTEGER_CONVERSION
#include "stb_vorbis.h"

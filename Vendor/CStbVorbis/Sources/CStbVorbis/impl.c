// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov
//
// Single translation unit that compiles the stb_vorbis implementation.
// Vendored from nothings/stb (stb_vorbis.c v1.22, public domain).
// Everything else imports the CStbVorbis module for the declarations.
//
// We feed OGG bytes off the network via the pushdata API, so the file/stdio API
// is disabled (STB_VORBIS_NO_STDIO). Pushdata stays enabled (it is the default).
#define STB_VORBIS_NO_STDIO
#include "stb_vorbis.h"

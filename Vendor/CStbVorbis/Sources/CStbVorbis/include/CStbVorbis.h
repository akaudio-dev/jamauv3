// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov
#pragma once
// Declarations-only view of the vendored stb_vorbis (implementation lives in
// impl.c). Swift imports the CStbVorbis module, which exposes this header, to
// reach the pushdata decode API (stb_vorbis_open_pushdata,
// stb_vorbis_decode_frame_pushdata, stb_vorbis_flush_pushdata, stb_vorbis_close).
#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.h"
#undef STB_VORBIS_HEADER_ONLY

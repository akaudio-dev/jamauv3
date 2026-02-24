//
//  jamauv3ExtensionParameterAddresses.h
//  jamauv3Extension
//
//  Created by Andrei Kozlov on 1/16/26.
//

#pragma once

#include <AudioToolbox/AUParameters.h>

// Parameter addresses as simple constants (C-compatible)
// User gain parameters for 8 NINJAM users (addresses 0-7)
static const int jamauv3ExtensionNumUsers = 8;
static const AUParameterAddress jamauv3ExtensionParameterAddress_userGainBase = 0;

// Signal parameter: extension sets to 1.0 when audio processing is needed
// (NINJAM connected or Icecast listening), 0.0 when idle.
// Host observes this on iOS to defer AVAudioEngine start for battery savings.
static const AUParameterAddress jamauv3ExtensionParameterAddress_needsAudio = 100;

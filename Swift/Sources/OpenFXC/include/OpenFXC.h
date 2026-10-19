// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause
//
// Umbrella header for the `OpenFXC` Swift module.
//
// This exposes the unmodified OpenFX C API headers from the repository's
// top-level `include/` directory to Swift, plus a small set of C shims
// (OpenFXSwiftShims.h) for the parts of the API Swift cannot express
// directly (C variadic functions).

#ifndef OPENFX_C_UMBRELLA_H
#define OPENFX_C_UMBRELLA_H

// ofxParametricParam.h uses `bool` without including <stdbool.h>, which is
// only an error when the headers are compiled as C (as Swift's importer does).
#include <stdbool.h>

#include "../../../../include/ofxCore.h"
#include "../../../../include/ofxProperty.h"
#include "../../../../include/ofxPixels.h"
#include "../../../../include/ofxMemory.h"
#include "../../../../include/ofxMultiThread.h"
#include "../../../../include/ofxMessage.h"
#include "../../../../include/ofxProgress.h"
#include "../../../../include/ofxTimeLine.h"
#include "../../../../include/ofxInteract.h"
#include "../../../../include/ofxKeySyms.h"
#include "../../../../include/ofxParam.h"
#include "../../../../include/ofxParametricParam.h"
#include "../../../../include/ofxImageEffect.h"
#include "../../../../include/ofxDialog.h"
#include "../../../../include/ofxDrawSuite.h"
#include "../../../../include/ofxColour.h"
#include "../../../../include/ofxGPURender.h"

#include "OpenFXSwiftShims.h"

#endif

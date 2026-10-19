// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause
//
// C shims for the parts of the OpenFX API that Swift cannot call or
// implement directly: the parameter suite's value accessors and the
// message suite are C variadic functions.
//
// Host side:   Swift registers non-variadic callbacks with
//              OfxSwiftSetHostParamCallbacks / OfxSwiftSetHostMessageCallbacks,
//              then calls OfxSwiftInstallVariadicParamFunctions /
//              OfxSwiftInstallVariadicMessageFunctions to fill the variadic
//              slots of its suite structs with C trampolines.
//
// Plug-in side: Swift calls the host's variadic functions through the
//              OfxSwiftCall* helpers, describing the value layout explicitly.

#ifndef OPENFX_SWIFT_SHIMS_H
#define OPENFX_SWIFT_SHIMS_H

#include "../../../../include/ofxCore.h"
#include "../../../../include/ofxParam.h"
#include "../../../../include/ofxMessage.h"

#ifdef __cplusplus
extern "C" {
#endif

/** How a parameter's value is passed through the variadic API. */
typedef enum OfxSwiftParamValueKind {
  OfxSwiftParamValueKindNone = 0,   ///< group, page, push button: no value
  OfxSwiftParamValueKindInt = 1,    ///< int / bool / choice: `int`s
  OfxSwiftParamValueKindDouble = 2, ///< double / colour / 2D / 3D: `double`s
  OfxSwiftParamValueKindString = 3, ///< string / custom / string choice: one `char *`
} OfxSwiftParamValueKind;

/** A non-variadic parameter value; up to four components. */
typedef struct OfxSwiftParamValue {
  int ints[4];
  double doubles[4];
  const char *string;
} OfxSwiftParamValue;

/** Which variadic accessor is being serviced. */
typedef enum OfxSwiftParamQuery {
  OfxSwiftParamQueryValue = 0,
  OfxSwiftParamQueryDerivative = 1,
  OfxSwiftParamQueryIntegral = 2,
} OfxSwiftParamQuery;

/* ------------------------------------------------------------------------ */
/* Host side                                                                */
/* ------------------------------------------------------------------------ */

typedef struct OfxSwiftHostParamCallbacks {
  /** Report how values of this parameter are passed. */
  OfxStatus (*getLayout)(OfxParamHandle param, OfxSwiftParamValueKind *kind, int *count);
  /** Read a value. `hasTime` is 0 for paramGetValue. For integrals, the range is [time, time2]. */
  OfxStatus (*getValue)(OfxParamHandle param, OfxSwiftParamQuery query, int hasTime,
                        OfxTime time, OfxTime time2, OfxSwiftParamValue *value);
  /** Write a value. `hasTime` is 0 for paramSetValue. */
  OfxStatus (*setValue)(OfxParamHandle param, int hasTime, OfxTime time,
                        const OfxSwiftParamValue *value);
} OfxSwiftHostParamCallbacks;

typedef struct OfxSwiftHostMessageCallbacks {
  /** Receives an already formatted message. `persistent` is 1 for setPersistentMessage. */
  OfxStatus (*message)(void *handle, const char *messageType, const char *messageId,
                       const char *message, int persistent);
  OfxStatus (*clearPersistentMessage)(void *handle);
} OfxSwiftHostMessageCallbacks;

void OfxSwiftSetHostParamCallbacks(OfxSwiftHostParamCallbacks callbacks);
void OfxSwiftSetHostMessageCallbacks(OfxSwiftHostMessageCallbacks callbacks);

/** Fill paramGetValue, paramGetValueAtTime, paramGetDerivative, paramGetIntegral,
    paramSetValue and paramSetValueAtTime with trampolines to the param callbacks. */
void OfxSwiftInstallVariadicParamFunctions(OfxParameterSuiteV1 *suite);

/** Fill the variadic members of the message suites with trampolines to the
    message callbacks. Either pointer may be NULL. */
void OfxSwiftInstallVariadicMessageFunctions(OfxMessageSuiteV1 *v1, OfxMessageSuiteV2 *v2);

/* ------------------------------------------------------------------------ */
/* Plug-in side                                                             */
/* ------------------------------------------------------------------------ */

/** Calls paramGetValue (hasTime == 0) or paramGetValueAtTime. */
OfxStatus OfxSwiftCallParamGetValue(const OfxParameterSuiteV1 *suite, OfxParamHandle param,
                                    int hasTime, OfxTime time, OfxSwiftParamValueKind kind,
                                    int count, OfxSwiftParamValue *value);

/** Calls paramGetDerivative (only meaningful for double valued params). */
OfxStatus OfxSwiftCallParamGetDerivative(const OfxParameterSuiteV1 *suite, OfxParamHandle param,
                                         OfxTime time, int count, OfxSwiftParamValue *value);

/** Calls paramGetIntegral (only meaningful for double valued params). */
OfxStatus OfxSwiftCallParamGetIntegral(const OfxParameterSuiteV1 *suite, OfxParamHandle param,
                                       OfxTime time1, OfxTime time2, int count,
                                       OfxSwiftParamValue *value);

/** Calls paramSetValue (hasTime == 0) or paramSetValueAtTime. */
OfxStatus OfxSwiftCallParamSetValue(const OfxParameterSuiteV1 *suite, OfxParamHandle param,
                                    int hasTime, OfxTime time, OfxSwiftParamValueKind kind,
                                    int count, const OfxSwiftParamValue *value);

/** Calls the V1 message function with a pre-formatted message. */
OfxStatus OfxSwiftCallMessage(const OfxMessageSuiteV1 *suite, void *handle,
                              const char *messageType, const char *messageId,
                              const char *message);

/** Calls the V2 setPersistentMessage function with a pre-formatted message. */
OfxStatus OfxSwiftCallSetPersistentMessage(const OfxMessageSuiteV2 *suite, void *handle,
                                           const char *messageType, const char *messageId,
                                           const char *message);

#ifdef __cplusplus
}
#endif

#endif

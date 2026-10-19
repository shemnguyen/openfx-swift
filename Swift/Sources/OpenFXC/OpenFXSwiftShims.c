// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

#include "include/OpenFXSwiftShims.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------------ */
/* Host side: variadic trampolines                                          */
/* ------------------------------------------------------------------------ */

static OfxSwiftHostParamCallbacks gParamCallbacks;
static OfxSwiftHostMessageCallbacks gMessageCallbacks;

void OfxSwiftSetHostParamCallbacks(OfxSwiftHostParamCallbacks callbacks) {
  gParamCallbacks = callbacks;
}

void OfxSwiftSetHostMessageCallbacks(OfxSwiftHostMessageCallbacks callbacks) {
  gMessageCallbacks = callbacks;
}

/* Reads `count` output pointers of the right kind from `ap` and stores `value` through them. */
static void storeValue(va_list ap, OfxSwiftParamValueKind kind, int count,
                       const OfxSwiftParamValue *value) {
  int i;
  switch (kind) {
  case OfxSwiftParamValueKindInt:
    for (i = 0; i < count && i < 4; ++i) {
      int *out = va_arg(ap, int *);
      if (out) *out = value->ints[i];
    }
    break;
  case OfxSwiftParamValueKindDouble:
    for (i = 0; i < count && i < 4; ++i) {
      double *out = va_arg(ap, double *);
      if (out) *out = value->doubles[i];
    }
    break;
  case OfxSwiftParamValueKindString: {
    const char **out = va_arg(ap, const char **);
    if (out) *out = value->string;
    break;
  }
  case OfxSwiftParamValueKindNone:
    break;
  }
}

/* Reads `count` values of the right kind from `ap` into `value`. */
static void loadValue(va_list ap, OfxSwiftParamValueKind kind, int count,
                      OfxSwiftParamValue *value) {
  int i;
  switch (kind) {
  case OfxSwiftParamValueKindInt:
    for (i = 0; i < count && i < 4; ++i) value->ints[i] = va_arg(ap, int);
    break;
  case OfxSwiftParamValueKindDouble:
    for (i = 0; i < count && i < 4; ++i) value->doubles[i] = va_arg(ap, double);
    break;
  case OfxSwiftParamValueKindString:
    value->string = va_arg(ap, const char *);
    break;
  case OfxSwiftParamValueKindNone:
    break;
  }
}

static OfxStatus getCommon(OfxParamHandle param, OfxSwiftParamQuery query, int hasTime,
                           OfxTime time, OfxTime time2, va_list ap) {
  OfxSwiftParamValueKind kind = OfxSwiftParamValueKindNone;
  int count = 0;
  OfxSwiftParamValue value;
  OfxStatus stat;

  if (!gParamCallbacks.getLayout || !gParamCallbacks.getValue) return kOfxStatErrUnsupported;
  stat = gParamCallbacks.getLayout(param, &kind, &count);
  if (stat != kOfxStatOK) return stat;
  if (query != OfxSwiftParamQueryValue && kind != OfxSwiftParamValueKindDouble)
    return kOfxStatErrUnsupported;

  memset(&value, 0, sizeof(value));
  stat = gParamCallbacks.getValue(param, query, hasTime, time, time2, &value);
  if (stat != kOfxStatOK) return stat;
  storeValue(ap, kind, count, &value);
  return kOfxStatOK;
}

static OfxStatus setCommon(OfxParamHandle param, int hasTime, OfxTime time, va_list ap) {
  OfxSwiftParamValueKind kind = OfxSwiftParamValueKindNone;
  int count = 0;
  OfxSwiftParamValue value;
  OfxStatus stat;

  if (!gParamCallbacks.getLayout || !gParamCallbacks.setValue) return kOfxStatErrUnsupported;
  stat = gParamCallbacks.getLayout(param, &kind, &count);
  if (stat != kOfxStatOK) return stat;

  memset(&value, 0, sizeof(value));
  loadValue(ap, kind, count, &value);
  return gParamCallbacks.setValue(param, hasTime, time, &value);
}

static OfxStatus trampolineGetValue(OfxParamHandle param, ...) {
  va_list ap;
  OfxStatus stat;
  va_start(ap, param);
  stat = getCommon(param, OfxSwiftParamQueryValue, 0, 0, 0, ap);
  va_end(ap);
  return stat;
}

static OfxStatus trampolineGetValueAtTime(OfxParamHandle param, OfxTime time, ...) {
  va_list ap;
  OfxStatus stat;
  va_start(ap, time);
  stat = getCommon(param, OfxSwiftParamQueryValue, 1, time, 0, ap);
  va_end(ap);
  return stat;
}

static OfxStatus trampolineGetDerivative(OfxParamHandle param, OfxTime time, ...) {
  va_list ap;
  OfxStatus stat;
  va_start(ap, time);
  stat = getCommon(param, OfxSwiftParamQueryDerivative, 1, time, 0, ap);
  va_end(ap);
  return stat;
}

static OfxStatus trampolineGetIntegral(OfxParamHandle param, OfxTime time1, OfxTime time2, ...) {
  va_list ap;
  OfxStatus stat;
  va_start(ap, time2);
  stat = getCommon(param, OfxSwiftParamQueryIntegral, 1, time1, time2, ap);
  va_end(ap);
  return stat;
}

static OfxStatus trampolineSetValue(OfxParamHandle param, ...) {
  va_list ap;
  OfxStatus stat;
  va_start(ap, param);
  stat = setCommon(param, 0, 0, ap);
  va_end(ap);
  return stat;
}

static OfxStatus trampolineSetValueAtTime(OfxParamHandle param, OfxTime time, ...) {
  va_list ap;
  OfxStatus stat;
  va_start(ap, time);
  stat = setCommon(param, 1, time, ap);
  va_end(ap);
  return stat;
}

void OfxSwiftInstallVariadicParamFunctions(OfxParameterSuiteV1 *suite) {
  if (!suite) return;
  suite->paramGetValue = trampolineGetValue;
  suite->paramGetValueAtTime = trampolineGetValueAtTime;
  suite->paramGetDerivative = trampolineGetDerivative;
  suite->paramGetIntegral = trampolineGetIntegral;
  suite->paramSetValue = trampolineSetValue;
  suite->paramSetValueAtTime = trampolineSetValueAtTime;
}

static OfxStatus postFormatted(void *handle, const char *messageType, const char *messageId,
                               int persistent, const char *format, va_list ap) {
  char stackBuffer[1024];
  char *buffer = stackBuffer;
  OfxStatus stat;
  va_list copy;
  int needed;

  if (!gMessageCallbacks.message) return kOfxStatFailed;
  if (!format) format = "";

  va_copy(copy, ap);
  needed = vsnprintf(stackBuffer, sizeof(stackBuffer), format, copy);
  va_end(copy);
  if (needed < 0) return kOfxStatFailed;
  if ((size_t)needed >= sizeof(stackBuffer)) {
    buffer = (char *)malloc((size_t)needed + 1);
    if (!buffer) return kOfxStatErrMemory;
    vsnprintf(buffer, (size_t)needed + 1, format, ap);
  }

  stat = gMessageCallbacks.message(handle, messageType, messageId, buffer, persistent);
  if (buffer != stackBuffer) free(buffer);
  return stat;
}

static OfxStatus trampolineMessage(void *handle, const char *messageType, const char *messageId,
                                   const char *format, ...) {
  va_list ap;
  OfxStatus stat;
  va_start(ap, format);
  stat = postFormatted(handle, messageType, messageId, 0, format, ap);
  va_end(ap);
  return stat;
}

static OfxStatus trampolineSetPersistentMessage(void *handle, const char *messageType,
                                                const char *messageId, const char *format, ...) {
  va_list ap;
  OfxStatus stat;
  va_start(ap, format);
  stat = postFormatted(handle, messageType, messageId, 1, format, ap);
  va_end(ap);
  return stat;
}

static OfxStatus trampolineClearPersistentMessage(void *handle) {
  if (!gMessageCallbacks.clearPersistentMessage) return kOfxStatOK;
  return gMessageCallbacks.clearPersistentMessage(handle);
}

void OfxSwiftInstallVariadicMessageFunctions(OfxMessageSuiteV1 *v1, OfxMessageSuiteV2 *v2) {
  if (v1) v1->message = trampolineMessage;
  if (v2) {
    v2->message = trampolineMessage;
    v2->setPersistentMessage = trampolineSetPersistentMessage;
    v2->clearPersistentMessage = trampolineClearPersistentMessage;
  }
}

/* ------------------------------------------------------------------------ */
/* Plug-in side: calling a host's variadic functions                        */
/* ------------------------------------------------------------------------ */

OfxStatus OfxSwiftCallParamGetValue(const OfxParameterSuiteV1 *suite, OfxParamHandle param,
                                    int hasTime, OfxTime time, OfxSwiftParamValueKind kind,
                                    int count, OfxSwiftParamValue *v) {
  if (!suite || !v) return kOfxStatErrBadHandle;
  if (hasTime && !suite->paramGetValueAtTime) return kOfxStatErrUnsupported;
  if (!hasTime && !suite->paramGetValue) return kOfxStatErrUnsupported;

#define OFXS_GET(...) \
  (hasTime ? suite->paramGetValueAtTime(param, time, __VA_ARGS__) \
           : suite->paramGetValue(param, __VA_ARGS__))

  switch (kind) {
  case OfxSwiftParamValueKindInt:
    switch (count) {
    case 1: return OFXS_GET(&v->ints[0]);
    case 2: return OFXS_GET(&v->ints[0], &v->ints[1]);
    case 3: return OFXS_GET(&v->ints[0], &v->ints[1], &v->ints[2]);
    case 4: return OFXS_GET(&v->ints[0], &v->ints[1], &v->ints[2], &v->ints[3]);
    }
    break;
  case OfxSwiftParamValueKindDouble:
    switch (count) {
    case 1: return OFXS_GET(&v->doubles[0]);
    case 2: return OFXS_GET(&v->doubles[0], &v->doubles[1]);
    case 3: return OFXS_GET(&v->doubles[0], &v->doubles[1], &v->doubles[2]);
    case 4: return OFXS_GET(&v->doubles[0], &v->doubles[1], &v->doubles[2], &v->doubles[3]);
    }
    break;
  case OfxSwiftParamValueKindString: {
    char *s = NULL;
    OfxStatus stat = OFXS_GET(&s);
    v->string = s;
    return stat;
  }
  case OfxSwiftParamValueKindNone:
    return kOfxStatOK;
  }
#undef OFXS_GET
  return kOfxStatErrValue;
}

OfxStatus OfxSwiftCallParamGetDerivative(const OfxParameterSuiteV1 *suite, OfxParamHandle param,
                                         OfxTime time, int count, OfxSwiftParamValue *v) {
  if (!suite || !v) return kOfxStatErrBadHandle;
  if (!suite->paramGetDerivative) return kOfxStatErrUnsupported;
  double *d = v->doubles;
  switch (count) {
  case 1: return suite->paramGetDerivative(param, time, &d[0]);
  case 2: return suite->paramGetDerivative(param, time, &d[0], &d[1]);
  case 3: return suite->paramGetDerivative(param, time, &d[0], &d[1], &d[2]);
  case 4: return suite->paramGetDerivative(param, time, &d[0], &d[1], &d[2], &d[3]);
  }
  return kOfxStatErrValue;
}

OfxStatus OfxSwiftCallParamGetIntegral(const OfxParameterSuiteV1 *suite, OfxParamHandle param,
                                       OfxTime time1, OfxTime time2, int count,
                                       OfxSwiftParamValue *v) {
  if (!suite || !v) return kOfxStatErrBadHandle;
  if (!suite->paramGetIntegral) return kOfxStatErrUnsupported;
  double *d = v->doubles;
  switch (count) {
  case 1: return suite->paramGetIntegral(param, time1, time2, &d[0]);
  case 2: return suite->paramGetIntegral(param, time1, time2, &d[0], &d[1]);
  case 3: return suite->paramGetIntegral(param, time1, time2, &d[0], &d[1], &d[2]);
  case 4: return suite->paramGetIntegral(param, time1, time2, &d[0], &d[1], &d[2], &d[3]);
  }
  return kOfxStatErrValue;
}

OfxStatus OfxSwiftCallParamSetValue(const OfxParameterSuiteV1 *suite, OfxParamHandle param,
                                    int hasTime, OfxTime time, OfxSwiftParamValueKind kind,
                                    int count, const OfxSwiftParamValue *v) {
  if (!suite || !v) return kOfxStatErrBadHandle;
  if (hasTime && !suite->paramSetValueAtTime) return kOfxStatErrUnsupported;
  if (!hasTime && !suite->paramSetValue) return kOfxStatErrUnsupported;

#define OFXS_SET(...) \
  (hasTime ? suite->paramSetValueAtTime(param, time, __VA_ARGS__) \
           : suite->paramSetValue(param, __VA_ARGS__))

  switch (kind) {
  case OfxSwiftParamValueKindInt:
    switch (count) {
    case 1: return OFXS_SET(v->ints[0]);
    case 2: return OFXS_SET(v->ints[0], v->ints[1]);
    case 3: return OFXS_SET(v->ints[0], v->ints[1], v->ints[2]);
    case 4: return OFXS_SET(v->ints[0], v->ints[1], v->ints[2], v->ints[3]);
    }
    break;
  case OfxSwiftParamValueKindDouble:
    switch (count) {
    case 1: return OFXS_SET(v->doubles[0]);
    case 2: return OFXS_SET(v->doubles[0], v->doubles[1]);
    case 3: return OFXS_SET(v->doubles[0], v->doubles[1], v->doubles[2]);
    case 4: return OFXS_SET(v->doubles[0], v->doubles[1], v->doubles[2], v->doubles[3]);
    }
    break;
  case OfxSwiftParamValueKindString:
    return OFXS_SET(v->string);
  case OfxSwiftParamValueKindNone:
    return kOfxStatOK;
  }
#undef OFXS_SET
  return kOfxStatErrValue;
}

OfxStatus OfxSwiftCallMessage(const OfxMessageSuiteV1 *suite, void *handle,
                              const char *messageType, const char *messageId,
                              const char *message) {
  if (!suite || !suite->message) return kOfxStatErrUnsupported;
  return suite->message(handle, messageType, messageId, "%s", message ? message : "");
}

OfxStatus OfxSwiftCallSetPersistentMessage(const OfxMessageSuiteV2 *suite, void *handle,
                                           const char *messageType, const char *messageId,
                                           const char *message) {
  if (!suite || !suite->setPersistentMessage) return kOfxStatErrUnsupported;
  return suite->setPersistentMessage(handle, messageType, messageId, "%s",
                                     message ? message : "");
}

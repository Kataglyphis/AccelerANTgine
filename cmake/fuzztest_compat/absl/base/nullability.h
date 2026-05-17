#ifndef KATAGLYPHIS_FUZZTEST_COMPAT_ABSL_BASE_NULLABILITY_H_
#define KATAGLYPHIS_FUZZTEST_COMPAT_ABSL_BASE_NULLABILITY_H_

#if defined(__has_include_next)
#if __has_include_next("absl/base/nullability.h")
#include_next "absl/base/nullability.h"
#else
#include "absl/base/config.h"
#include "absl/base/internal/nullability_impl.h"

namespace absl {
ABSL_NAMESPACE_BEGIN

template <typename T>
using Nonnull = nullability_internal::NonnullImpl<T>;

template <typename T>
using Nullable = nullability_internal::NullableImpl<T>;

template <typename T>
using NullabilityUnknown = nullability_internal::NullabilityUnknownImpl<T>;

ABSL_NAMESPACE_END
}  // namespace absl

#if ABSL_HAVE_FEATURE(nullability_on_classes)
#define ABSL_NULLABILITY_COMPATIBLE _Nullable
#else
#define ABSL_NULLABILITY_COMPATIBLE
#endif
#endif
#else
#include "absl/base/config.h"
#include "absl/base/internal/nullability_impl.h"

namespace absl {
ABSL_NAMESPACE_BEGIN

template <typename T>
using Nonnull = nullability_internal::NonnullImpl<T>;

template <typename T>
using Nullable = nullability_internal::NullableImpl<T>;

template <typename T>
using NullabilityUnknown = nullability_internal::NullabilityUnknownImpl<T>;

ABSL_NAMESPACE_END
}  // namespace absl

#if ABSL_HAVE_FEATURE(nullability_on_classes)
#define ABSL_NULLABILITY_COMPATIBLE _Nullable
#else
#define ABSL_NULLABILITY_COMPATIBLE
#endif
#endif

#ifndef absl_nonnull
#define absl_nonnull
#endif

#ifndef absl_nullable
#define absl_nullable
#endif

#ifndef absl_nullability_unknown
#define absl_nullability_unknown
#endif

#endif  // KATAGLYPHIS_FUZZTEST_COMPAT_ABSL_BASE_NULLABILITY_H_

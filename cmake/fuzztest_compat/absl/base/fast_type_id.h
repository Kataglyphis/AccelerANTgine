#ifndef KATAGLYPHIS_FUZZTEST_COMPAT_ABSL_BASE_FAST_TYPE_ID_H_
#define KATAGLYPHIS_FUZZTEST_COMPAT_ABSL_BASE_FAST_TYPE_ID_H_

#if defined(__has_include_next)
#if __has_include_next("absl/base/fast_type_id.h")
#include_next "absl/base/fast_type_id.h"
#else
#include "absl/base/config.h"
#include "absl/base/internal/fast_type_id.h"

namespace absl {
ABSL_NAMESPACE_BEGIN

using FastTypeIdType = base_internal::FastTypeIdType;

template <typename Type>
constexpr inline FastTypeIdType FastTypeId() {
  return base_internal::FastTypeId<Type>();
}

ABSL_NAMESPACE_END
}  // namespace absl
#endif
#else
#include "absl/base/config.h"
#include "absl/base/internal/fast_type_id.h"

namespace absl {
ABSL_NAMESPACE_BEGIN

using FastTypeIdType = base_internal::FastTypeIdType;

template <typename Type>
constexpr inline FastTypeIdType FastTypeId() {
  return base_internal::FastTypeId<Type>();
}

ABSL_NAMESPACE_END
}  // namespace absl
#endif

#endif  // KATAGLYPHIS_FUZZTEST_COMPAT_ABSL_BASE_FAST_TYPE_ID_H_

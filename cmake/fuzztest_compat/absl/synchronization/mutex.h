// FUZZTEST's current sources still construct Abseil lock guards from Mutex
// references while the pinned top-level Abseil snapshot only accepts pointers.
// Keep that API bridge in the project-owned compatibility overlay.

#ifndef KATAGLYPHIS_FUZZTEST_COMPAT_ABSL_SYNCHRONIZATION_MUTEX_H_
#define KATAGLYPHIS_FUZZTEST_COMPAT_ABSL_SYNCHRONIZATION_MUTEX_H_

#define MutexLock KataglyphisAbslMutexLockBase
#define ReaderMutexLock KataglyphisAbslReaderMutexLockBase
#define WriterMutexLock KataglyphisAbslWriterMutexLockBase
#include_next "absl/synchronization/mutex.h"
#undef WriterMutexLock
#undef ReaderMutexLock
#undef MutexLock

namespace absl {
ABSL_NAMESPACE_BEGIN

class ABSL_SCOPED_LOCKABLE MutexLock {
 public:
  explicit MutexLock(Mutex* mu) ABSL_EXCLUSIVE_LOCK_FUNCTION(mu) : impl_(mu) {}

  explicit MutexLock(Mutex& mu) ABSL_EXCLUSIVE_LOCK_FUNCTION(mu)
      : impl_(&mu) {}

  explicit MutexLock(Mutex* mu, const Condition& cond)
      ABSL_EXCLUSIVE_LOCK_FUNCTION(mu)
      : impl_(mu, cond) {}

  explicit MutexLock(Mutex& mu, const Condition& cond)
      ABSL_EXCLUSIVE_LOCK_FUNCTION(mu)
      : impl_(&mu, cond) {}

  MutexLock(const MutexLock&) = delete;
  MutexLock(MutexLock&&) = delete;
  MutexLock& operator=(const MutexLock&) = delete;
  MutexLock& operator=(MutexLock&&) = delete;

  ~MutexLock() ABSL_UNLOCK_FUNCTION() = default;

 private:
  KataglyphisAbslMutexLockBase impl_;
};

class ABSL_SCOPED_LOCKABLE ReaderMutexLock {
 public:
  explicit ReaderMutexLock(Mutex* mu) ABSL_SHARED_LOCK_FUNCTION(mu)
      : impl_(mu) {}

  explicit ReaderMutexLock(Mutex& mu) ABSL_SHARED_LOCK_FUNCTION(mu)
      : impl_(&mu) {}

  explicit ReaderMutexLock(Mutex* mu, const Condition& cond)
      ABSL_SHARED_LOCK_FUNCTION(mu)
      : impl_(mu, cond) {}

  explicit ReaderMutexLock(Mutex& mu, const Condition& cond)
      ABSL_SHARED_LOCK_FUNCTION(mu)
      : impl_(&mu, cond) {}

  ReaderMutexLock(const ReaderMutexLock&) = delete;
  ReaderMutexLock(ReaderMutexLock&&) = delete;
  ReaderMutexLock& operator=(const ReaderMutexLock&) = delete;
  ReaderMutexLock& operator=(ReaderMutexLock&&) = delete;

  ~ReaderMutexLock() ABSL_UNLOCK_FUNCTION() = default;

 private:
  KataglyphisAbslReaderMutexLockBase impl_;
};

class ABSL_SCOPED_LOCKABLE WriterMutexLock {
 public:
  explicit WriterMutexLock(Mutex* mu) ABSL_EXCLUSIVE_LOCK_FUNCTION(mu)
      : impl_(mu) {}

  explicit WriterMutexLock(Mutex& mu) ABSL_EXCLUSIVE_LOCK_FUNCTION(mu)
      : impl_(&mu) {}

  explicit WriterMutexLock(Mutex* mu, const Condition& cond)
      ABSL_EXCLUSIVE_LOCK_FUNCTION(mu)
      : impl_(mu, cond) {}

  explicit WriterMutexLock(Mutex& mu, const Condition& cond)
      ABSL_EXCLUSIVE_LOCK_FUNCTION(mu)
      : impl_(&mu, cond) {}

  WriterMutexLock(const WriterMutexLock&) = delete;
  WriterMutexLock(WriterMutexLock&&) = delete;
  WriterMutexLock& operator=(const WriterMutexLock&) = delete;
  WriterMutexLock& operator=(WriterMutexLock&&) = delete;

  ~WriterMutexLock() ABSL_UNLOCK_FUNCTION() = default;

 private:
  KataglyphisAbslWriterMutexLockBase impl_;
};

ABSL_NAMESPACE_END
}  // namespace absl

#endif  // KATAGLYPHIS_FUZZTEST_COMPAT_ABSL_SYNCHRONIZATION_MUTEX_H_

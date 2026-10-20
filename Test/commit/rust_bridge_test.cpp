#include "rusty_bridge/lib.h"

#include <gtest/gtest.h>

#include <cstdint>

extern "C" std::int32_t rusty_extern_c_integer();

// The crate is linked into every build; a call fails the link if it ever goes missing.
TEST(RustCrate, CxxBridgeReturnsItsConstant) { EXPECT_EQ(rusty_cxxbridge_integer(), 42); }

TEST(RustCrate, ExternCFunctionReturnsItsConstant) { EXPECT_EQ(rusty_extern_c_integer(), 322); }

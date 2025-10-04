#include "KataglyphisCppProjectConfig.hpp"
#include <iostream>

extern "C" {
int32_t rusty_extern_c_integer();
}

/**
 * @brief Entry point for the application.
 *
 * This function initializes the program, optionally invokes an 
 * external Rust-provided routine, and then prints a greeting message
 * to the standard output. It demonstrates integration between C++
 * and an `extern "C"` Rust function, controlled via the compile-time
 * configuration flag `USE_RUST`.
 *
 * @details
 * - Checks the preprocessor symbol `USE_RUST` to determine whether to call
 *   the external Rust function `rusty_extern_c_integer()`. If enabled,
 *   it prints the integer value returned by that function, prefixed
 *   with a descriptive message.
 * - Always prints a friendly `"Hello World!"` greeting to the console,
 *   regardless of whether the Rust call was made.
 * - Ensures proper linkage with Rust code via `extern "C"` to prevent
 *   C++ name mangling when calling `rusty_extern_c_integer()`.
 *
 * @pre
 * - If `USE_RUST` is defined and non-zero, the Rust library providing
 *   `rusty_extern_c_integer()` must be correctly linked into the final
 *   executable.
 * - `KataglyphisCppProjectConfig.hpp` must define `USE_RUST` consistently
 *   with the availability of the Rust symbol.
 *
 * @post
 * - Standard output will contain:
 *     - If `USE_RUST` is true:  
 *       `A value given directly by extern c function <n>`
 *     - Always:  
 *       `Hello World!`
 *
 * @return Returns 0 on successful execution. Non-zero return codes
 *         are not used in the current implementation but may be
 *         adopted in future extensions to signal error conditions.
 *
 * @see rusty_extern_c_integer()
 */
int main()
{
    if (USE_RUST) { std::cout << "A value given directly by extern c function " << rusty_extern_c_integer() << "\n"; }
    std::cout << "Hello World! " << "\n";
    return 0;
}

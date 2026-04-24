#include <cstddef>
#include <cstdint>
#include <string>

import kataglyphis.toml_config;
import kataglyphis.config_loader;

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size)
{
    const std::string input(reinterpret_cast<const char *>(data), size);

    auto toml_result = kataglyphis::config::parse_inference_config(input);
    (void)toml_result;

    auto json_result = kataglyphis::config::parse_webrtc_config(input);
    (void)json_result;

    return 0;
}
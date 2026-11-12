// A stand-in plugin module for the commit suite, not AMD's: it keeps three rules read in AMD's source and runs no node.
#include <onnxruntime_c_api.h>

#include <cctype>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <map>
#include <string>
#include <thread>

namespace {

const OrtApi *api = nullptr;
const OrtEpApi *ep_api = nullptr;
std::string registered_name;

auto refuse(const std::string &message) -> OrtStatus *
{ return api->CreateStatus(ORT_INVALID_ARGUMENT, message.c_str()); }

struct StubEp : OrtEp
{
    StubEp() : OrtEp{}
    {
        ort_version_supported = ORT_API_VERSION;
        GetName = [](const OrtEp *) noexcept -> const char * { return registered_name.c_str(); };
        // No node is claimed, so the model's own nodes stay on the CPU provider.
        GetCapability = [](OrtEp *, const OrtGraph *, OrtEpGraphSupportInfo *) noexcept -> OrtStatus * {
            return nullptr;
        };
        Compile =
          [](OrtEp *, const OrtGraph **, const OrtNode **, std::size_t, OrtNodeComputeInfo **, OrtNode **) noexcept
          -> OrtStatus * { return refuse("the stand-in plugin compiles nothing"); };
        ReleaseNodeComputeInfos = [](OrtEp *, OrtNodeComputeInfo **, std::size_t) noexcept {};
    }
};

// As AMD's module reads them: its own prefix is cut off, every other ep.* key keeps its full name.
auto session_ep_options(const OrtSessionOptions *session_options, std::map<std::string, std::string> &options)
  -> OrtStatus *
{
    OrtKeyValuePairs *entries = nullptr;
    if (OrtStatus *status = api->GetSessionOptionsConfigEntries(session_options, &entries)) { return status; }
    const char *const *keys = nullptr;
    const char *const *values = nullptr;
    std::size_t count = 0;
    api->GetKeyValuePairs(entries, &keys, &values, &count);
    std::string prefix = "ep." + registered_name + ".";
    for (char &letter : prefix) { letter = static_cast<char>(std::tolower(static_cast<unsigned char>(letter))); }
    for (std::size_t i = 0; i < count; ++i) {
        const std::string key = keys[i];
        if (key.rfind(prefix, 0) == 0) {
            options.emplace(key.substr(prefix.size()), values[i]);
        } else if (key.rfind("ep.", 0) == 0) {
            options.emplace(key, values[i]);
        }
    }
    api->ReleaseKeyValuePairs(entries);
    return nullptr;
}

auto create_ep(OrtEpFactory *,
  const OrtHardwareDevice *const *,
  const OrtKeyValuePairs *const *,
  std::size_t device_count,
  const OrtSessionOptions *session_options,
  const OrtLogger *,
  OrtEp **ep) noexcept -> OrtStatus *
{
    *ep = nullptr;
    std::map<std::string, std::string> options;
    if (OrtStatus *status = session_ep_options(session_options, options)) { return status; }
    std::string seen = "devices=" + std::to_string(device_count);
    for (const auto &[key, value] : options) { seen += " " + key + "=" + value; }
    if (const char *log = std::getenv("KATAGLYPHIS_STUB_EP_LOG")) { std::ofstream(log, std::ios::app) << seen << "\n"; }
    if (device_count > 1) { return refuse("the stand-in plugin, as AMD's, takes a single device"); }
    for (const auto &[key, value] : options) {
        if (key != "device_id") { return refuse("Unknown provider option: " + key); }
    }
    *ep = new StubEp;
    return nullptr;
}

// Offers as many devices as the test asks for, each on the first CPU the runtime lists.
auto supported_devices(OrtEpFactory *factory,
  const OrtHardwareDevice *const *devices,
  std::size_t device_count,
  OrtEpDevice **ep_devices,
  std::size_t ep_device_limit,
  std::size_t *ep_device_count) noexcept -> OrtStatus *
{
    *ep_device_count = 0;
    const char *wanted_text = std::getenv("KATAGLYPHIS_STUB_EP_DEVICES");
    const std::size_t wanted = wanted_text == nullptr ? 1 : std::strtoul(wanted_text, nullptr, 10);
    for (std::size_t i = 0; i < device_count; ++i) {
        if (api->HardwareDevice_Type(devices[i]) != OrtHardwareDeviceType_CPU) { continue; }
        while (*ep_device_count < wanted && *ep_device_count < ep_device_limit) {
            if (OrtStatus *status =
                  ep_api->CreateEpDevice(factory, devices[i], nullptr, nullptr, &ep_devices[*ep_device_count])) {
                return status;
            }
            ++*ep_device_count;
        }
        break;
    }
    return nullptr;
}

struct StubFactory : OrtEpFactory
{
    StubFactory() : OrtEpFactory{}
    {
        ort_version_supported = ORT_API_VERSION;
        // The registration name is the provider's name, as in AMD's module.
        GetName = [](const OrtEpFactory *) noexcept -> const char * { return registered_name.c_str(); };
        GetVendor = [](const OrtEpFactory *) noexcept -> const char * { return "Kataglyphis test stand-in"; };
        GetVendorId = [](const OrtEpFactory *) noexcept -> std::uint32_t { return 0; };
        GetVersion = [](const OrtEpFactory *) noexcept -> const char * { return "0.0.0"; };
        GetSupportedDevices = supported_devices;
        CreateEp = create_ep;
        ReleaseEp = [](OrtEpFactory *, OrtEp *ep) noexcept { delete static_cast<StubEp *>(ep); };
        // ONNX Runtime calls these two without asking whether they are set.
        CreateDataTransfer = [](OrtEpFactory *, OrtDataTransferImpl **transfer) noexcept -> OrtStatus * {
            *transfer = nullptr;
            return nullptr;
        };
        IsStreamAware = [](const OrtEpFactory *) noexcept { return false; };
    }
};

}// namespace

extern "C" {

__attribute__((visibility("default"))) OrtStatus *CreateEpFactories(const char *name,
  const OrtApiBase *api_base,
  const OrtLogger *,
  OrtEpFactory **factories,
  std::size_t factory_limit,
  std::size_t *factory_count)
{
    api = api_base->GetApi(ORT_API_VERSION);
    ep_api = api->GetEpApi();
    if (factory_limit < 1) { return refuse("no room for the stand-in factory"); }
    // A slow registration keeps the name free long enough for every waiting thread to ask for it.
    if (const char *delay = std::getenv("KATAGLYPHIS_STUB_EP_REGISTER_MS")) {
        std::this_thread::sleep_for(std::chrono::milliseconds(std::strtol(delay, nullptr, 10)));
    }
    registered_name = name;
    static StubFactory factory;
    factories[0] = &factory;
    *factory_count = 1;
    return nullptr;
}

__attribute__((visibility("default"))) OrtStatus *ReleaseEpFactory(OrtEpFactory *) { return nullptr; }

}// extern "C"

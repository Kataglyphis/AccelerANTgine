export module kataglyphis.execution_provider;

export namespace kataglyphis::inference {

// The one provider list; the text generator answers ProviderUnavailable for the ones GenAI has no route to.
enum class ExecutionProvider { Cpu, Cuda, MigraphX, DirectML, Xnnpack, Dnnl };

}// namespace kataglyphis::inference

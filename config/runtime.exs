import Config

Application.ensure_all_started(:logger_backends)
LoggerBackends.add(RingLogger)

# Erlang log into the kernel log, which the RAM console keeps across reboots
if config_target() != :host and Code.ensure_loaded?(Kuroneko.KmsgLogger) do
  Kuroneko.KmsgLogger.add()
end

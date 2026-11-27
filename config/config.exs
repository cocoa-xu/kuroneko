# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://nerves.hexdocs.pm/advanced-configuration.html for details.

config :nerves, :firmware,
  rootfs_overlay: "rootfs_overlay",
  provisioning: "config/provisioning.conf"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1794853376"

# The pages, made with Phoenix LiveView. Kuroneko.Web serves HTTP and HTTPS
# and hands them to the endpoint, which runs no server of its own.
config :kuroneko, KuronekoWeb.Endpoint,
  server: false,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: KuronekoWeb.ErrorHTML], layout: false],
  pubsub_server: Kuroneko.PubSub,
  live_view: [signing_salt: "kuroneko live view"]

config :phoenix, :json_library, Jason
config :phoenix_live_view, root_tag_attribute: "phx-r"

config :esbuild,
  version: "0.28.2",
  kuroneko: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.3.5",
  kuroneko: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end

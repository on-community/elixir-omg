defmodule OMG.SocketClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :omg_socket_client,
      version: OMG.Umbrella.MixProject.umbrella_version(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.6",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(_), do: ["lib", "test/support"]

  defp deps do
    [
      {:phoenix_client, "~> 0.3", only: [:dev]},
      {:websocket_client, "~> 1.3", only: [:dev]},
      {:jason, "~> 1.0", only: [:dev]},
    ]
  end
end

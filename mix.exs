defmodule PyreClient.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/chrislaskey/pyre_client"

  def project do
    [
      app: :pyre_client,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Execution layer and thin WebSocket client for Pyre",
      package: package(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # LLM API client — direct dep, NO jido transitive dependency
      # Used by ReqLLM backend, AgenticLoop, and tool type definitions
      {:req_llm, "~> 1.10"},

      # WebSocket client — git fork with OTP ping/pong support.
      # override: true because req_llm also depends on websockex from Hex.
      {:websockex, "~> 0.5", git: "https://github.com/dominicletz/websockex", override: true},

      # JSON encoding (also pulled in by req_llm, but explicit for clarity)
      {:jason, "~> 1.2"},

      # Testing
      {:bandit, "~> 1.5", only: :test},
      {:phoenix, "~> 1.8", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end
end

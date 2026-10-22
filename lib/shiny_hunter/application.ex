defmodule ShinyHunter.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    ShinyHunter.Encounters.load()

    children = [
      ShinyHunterWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:shiny_hunter, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ShinyHunter.PubSub},
      {Task.Supervisor, name: ShinyHunter.TaskSupervisor},
      ShinyHunter.Hunt,
      # Start to serve requests, typically the last entry
      ShinyHunterWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ShinyHunter.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ShinyHunterWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

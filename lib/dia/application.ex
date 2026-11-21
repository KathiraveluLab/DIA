defmodule Dia.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DiaWeb.Telemetry,
      Dia.Repo,
      {Ecto.Migrator, repos: Application.fetch_env!(:dia, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:dia, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Dia.PubSub},
      {Task.Supervisor, name: Dia.TaskSupervisor},
      Dia.Dimse.Receiver,
      DiaWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Dia.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    DiaWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    System.get_env("RELEASE_NAME") == nil
  end
end

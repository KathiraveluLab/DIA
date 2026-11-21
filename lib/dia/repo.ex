defmodule Dia.Repo do
  use Ecto.Repo,
    otp_app: :dia,
    adapter: Ecto.Adapters.SQLite3
end

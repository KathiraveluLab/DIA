defmodule Mix.Tasks.Dia.SeedSample do
  @moduledoc """
  Generates a zero-PHI synthetic DICOM Part 10 cohort and seeds DIA's SQLite catalog.

      mix dia.seed_sample
      mix dia.seed_sample --dir /tmp/my_dicoms
  """
  use Mix.Task

  @shortdoc "Seeds a synthetic zero-PHI DICOM archive and sample albums"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [dir: :string])
    dir = Keyword.get(opts, :dir, Dia.SampleData.default_dir())

    {:ok, source} = Dia.SampleData.seed!(dir)

    Mix.shell().info(
      "Seeded #{source.files_indexed} DICOM instances (#{source.files_quarantined} quarantined) in #{source.root_path}"
    )
  end
end

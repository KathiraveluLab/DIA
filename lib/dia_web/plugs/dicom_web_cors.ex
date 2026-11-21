defmodule DiaWeb.Plugs.DicomWebCors do
  @moduledoc """
  Adds CORS headers required by browser-based DICOMweb viewers such as OHIF Viewer
  and responds cleanly to OPTIONS preflight requests.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn =
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
      |> put_resp_header(
        "access-control-allow-headers",
        "Accept, Authorization, Content-Type, Origin, Range"
      )
      |> put_resp_header(
        "access-control-expose-headers",
        "Content-Type, Content-Length, Content-Range"
      )

    if conn.method == "OPTIONS" do
      conn
      |> send_resp(:no_content, "")
      |> halt()
    else
      conn
    end
  end
end

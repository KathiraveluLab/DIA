defmodule Dia.Kheops.Client do
  @moduledoc """
  HTTP client built on `:req` for publishing DIA albums to Kheops via REST and DICOMweb STOW-RS.
  """

  @doc """
  Creates a new album on a Kheops server via `POST /api/albums`.
  """
  @spec create_album(String.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, %{album_id: String.t(), share_url: String.t()}} | {:error, term()}
  def create_album(base_url, bearer_token, album_name, description \\ nil, opts \\ []) do
    url = String.trim_trailing(base_url, "/") <> "/api/albums"

    payload =
      %{"album_name" => album_name}
      |> maybe_put("description", description)

    req_opts =
      base_req_options(opts) ++
        [
          url: url,
          headers: [
            {"authorization", "Bearer #{bearer_token}"},
            {"accept", "application/json"}
          ],
          json: payload
        ]

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        album_id = extract_album_id(body)
        share_url = build_share_url(base_url, album_id, body)
        {:ok, %{album_id: album_id, share_url: share_url}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Uploads a DICOM Part 10 binary to Kheops using DICOMweb STOW-RS (`multipart/related; type="application/dicom"`).
  """
  @spec stow_instance(String.t(), String.t(), binary(), keyword()) ::
          {:ok, map() | binary()} | {:error, term()}
  def stow_instance(base_url, bearer_token, dicom_binary, opts \\ [])
      when is_binary(dicom_binary) do
    boundary = "dia_stow_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    link_token = Keyword.get(opts, :link_token)
    album_id = Keyword.get(opts, :album_id)

    base = String.trim_trailing(base_url, "/")

    url =
      cond do
        is_binary(link_token) and link_token != "" ->
          "#{base}/api/link/#{link_token}/studies"

        is_binary(album_id) and album_id != "" ->
          "#{base}/api/studies?album=#{URI.encode_www_form(album_id)}"

        true ->
          "#{base}/api/studies"
      end

    body = build_multipart_dicom_body(dicom_binary, boundary)

    req_opts =
      base_req_options(opts) ++
        [
          url: url,
          headers: [
            {"authorization", "Bearer #{bearer_token}"},
            {"content-type",
             ~s(multipart/related; type="application/dicom"; boundary="#{boundary}")},
            {"accept", "application/dicom+json, application/json"}
          ],
          body: body
        ]

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Formats a DICOM Part 10 binary into a DICOMweb STOW-RS MIME `multipart/related` body.
  """
  @spec build_multipart_dicom_body(binary(), String.t()) :: binary()
  def build_multipart_dicom_body(dicom_binary, boundary) do
    IO.iodata_to_binary([
      "--",
      boundary,
      "\r\n",
      "Content-Type: application/dicom\r\n",
      "\r\n",
      dicom_binary,
      "\r\n--",
      boundary,
      "--\r\n"
    ])
  end

  defp base_req_options(opts) do
    default_opts = Application.get_env(:dia, :kheops_req_options, [])
    extra_opts = Keyword.get(opts, :req_options, [])

    Keyword.merge(
      [retry: false, receive_timeout: 60_000],
      Keyword.merge(default_opts, extra_opts)
    )
  end

  defp extract_album_id(%{"album_id" => id}) when is_binary(id), do: id
  defp extract_album_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_album_id(%{"id" => id}) when is_integer(id), do: Integer.to_string(id)
  defp extract_album_id(_), do: nil

  defp build_share_url(_base_url, _album_id, %{"share_url" => url}) when is_binary(url), do: url
  defp build_share_url(_base_url, _album_id, %{"url" => url}) when is_binary(url), do: url

  defp build_share_url(base_url, album_id, _body) when is_binary(album_id) do
    String.trim_trailing(base_url, "/") <> "/albums/" <> album_id
  end

  defp build_share_url(base_url, _, _), do: String.trim_trailing(base_url, "/")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end

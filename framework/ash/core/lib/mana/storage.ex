defmodule Mana.Storage do
  @moduledoc """
  Object storage for uploads and generated files. Clients upload straight to the
  store with a short-lived signed URL and read through signed URLs; the API never
  proxies bytes and never hands out storage keys as URLs.

      config :mana_core, Mana.Storage, adapter: Mana.Storage.S3     # production
      config :mana_core, Mana.Storage, adapter: Mana.Storage.Local,  # development
        root: "/var/tmp/my-app-files", base_url: "http://127.0.0.1:4000/__storage", secret: "..."

  Read URLs are signed at the start of a window half their lifetime long, so the
  same object keeps the same URL (and stays cached) while it remains valid for at
  least half its lifetime.
  """
  use Mana.Integration, otp_app: :mana_core

  @type upload :: %{url: String.t(), method: String.t(), content_type: String.t(), expires_at: DateTime.t()}

  @callback upload_url(key :: String.t(), content_type :: String.t(), signed_at :: DateTime.t(), ttl :: pos_integer) :: upload
  @callback read_url(key :: String.t(), signed_at :: DateTime.t(), ttl :: pos_integer) :: String.t()
  @callback put(key :: String.t(), body :: iodata, content_type :: String.t()) :: :ok | {:error, term}
  @callback delete(key :: String.t()) :: :ok | {:error, term}
  @callback exists?(key :: String.t()) :: boolean
  @callback get(key :: String.t()) :: {:ok, binary} | {:error, term}

  def upload_url(key, content_type, ttl \\ 3600),
    do: adapter().upload_url(safe!(key), content_type, DateTime.utc_now(), ttl)

  def read_url(key, ttl \\ 3600) do
    half = max(div(ttl, 2), 1)
    window = div(System.os_time(:second), half) * half
    adapter().read_url(safe!(key), DateTime.from_unix!(window), ttl)
  end

  def put(key, body, content_type), do: adapter().put(safe!(key), body, content_type)
  def delete(key), do: adapter().delete(safe!(key))
  def exists?(key), do: adapter().exists?(safe!(key))
  def get(key), do: adapter().get(safe!(key))

  defp safe!(key) do
    if is_binary(key) and Regex.match?(~r{\A[a-zA-Z0-9_\-]+(/[a-zA-Z0-9_\-.]+)*\z}, key) and
         not String.contains?(key, ".."),
       do: key,
       else: raise(ArgumentError, "unsafe storage key")
  end
end

defmodule Mana.Storage.S3 do
  @moduledoc "Any S3-compatible store (AWS S3, Cloudflare R2, MinIO); SigV4 from Req."
  use Mana.Integration.Adapter,
    slot: Mana.Storage,
    env: ["S3_ENDPOINT", "S3_BUCKET_DEFAULT", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY"]

  def upload_url(key, content_type, signed_at, ttl) do
    %{
      url: presign(key, :put, signed_at, ttl),
      method: "PUT",
      content_type: content_type,
      expires_at: DateTime.add(signed_at, ttl)
    }
  end

  def read_url(key, signed_at, ttl), do: presign(key, :get, signed_at, ttl)

  def put(key, body, content_type) do
    case Req.put(url(key), body: body, headers: [{"content-type", content_type}], aws_sigv4: sigv4(), retry: :transient) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, other}
    end
  end

  def delete(key) do
    case Req.delete(url(key), aws_sigv4: sigv4(), retry: :transient) do
      {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
      other -> {:error, other}
    end
  end

  def exists?(key), do: match?({:ok, %{status: 200}}, Req.head(url(key), aws_sigv4: sigv4(), retry: false))

  def get(key) do
    case Req.get(url(key), aws_sigv4: sigv4(), retry: :transient, decode_body: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      other -> {:error, other}
    end
  end

  defp presign(key, method, signed_at, ttl) do
    ReqS3.presign_url(
      bucket: env!("S3_BUCKET_DEFAULT"),
      key: key,
      method: method,
      endpoint_url: env!("S3_ENDPOINT"),
      access_key_id: env!("S3_ACCESS_KEY_ID"),
      secret_access_key: env!("S3_SECRET_ACCESS_KEY"),
      region: region(),
      datetime: signed_at,
      expires: ttl
    )
  end

  defp url(key), do: "#{String.trim_trailing(env!("S3_ENDPOINT"), "/")}/#{env!("S3_BUCKET_DEFAULT")}/#{key}"

  defp sigv4,
    do: [service: "s3", region: region(), access_key_id: env!("S3_ACCESS_KEY_ID"), secret_access_key: env!("S3_SECRET_ACCESS_KEY")]

  defp region, do: System.get_env("S3_REGION") |> then(&if(&1 in [nil, ""], do: "auto", else: &1))
end

defmodule Mana.Storage.Local do
  @moduledoc """
  Development store on local disk. URLs point at `Mana.Storage.LocalPlug`, which
  checks an HMAC over method, key and expiry exactly like a presigned URL would.
  """
  use Mana.Integration.Adapter, slot: Mana.Storage, fake: true

  def upload_url(key, content_type, signed_at, ttl) do
    expires = DateTime.add(signed_at, ttl)
    %{url: signed("PUT", key, expires), method: "PUT", content_type: content_type, expires_at: expires}
  end

  def read_url(key, signed_at, ttl), do: signed("GET", key, DateTime.add(signed_at, ttl))

  def put(key, body, _content_type) do
    path = path(key)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, body)
  end

  def delete(key) do
    case File.rm(path(key)) do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  def exists?(key), do: File.regular?(path(key))
  def get(key), do: File.read(path(key))

  @doc false
  def path(key), do: Path.join(config()[:root], key)

  @doc false
  def signature(method, key, expires_unix),
    do: :crypto.mac(:hmac, :sha256, config()[:secret], "#{method}\n#{key}\n#{expires_unix}") |> Base.url_encode64(padding: false)

  defp signed(method, key, expires) do
    unix = DateTime.to_unix(expires)
    "#{config()[:base_url]}/#{key}?" <> URI.encode_query(expires: unix, signature: signature(method, key, unix))
  end

  defp config, do: Application.fetch_env!(:mana_core, Mana.Storage)
end

if Code.ensure_loaded?(Plug.Conn) do
  defmodule Mana.Storage.LocalPlug do
    @moduledoc "Serves `Mana.Storage.Local` signed URLs. Mount only in development."
    import Plug.Conn
    def init(options), do: options

    def call(%{method: method, path_info: parts} = conn, _) when method in ["GET", "PUT"] and parts != [] do
      key = Enum.join(parts, "/")
      conn = fetch_query_params(conn)

      with %{"expires" => expires, "signature" => signature} <- conn.query_params,
           {unix, ""} <- Integer.parse(expires),
           true <- unix > System.os_time(:second),
           true <- Plug.Crypto.secure_compare(signature, Mana.Storage.Local.signature(method, key, unix)) do
        serve(conn, method, key)
      else
        _ -> conn |> send_resp(403, "") |> halt()
      end
    end

    # Browsers preflight cross-origin uploads; the signature still guards the PUT.
    def call(%{method: "OPTIONS"} = conn, _) do
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-methods", "GET,PUT")
      |> put_resp_header("access-control-allow-headers", "content-type")
      |> send_resp(204, "")
      |> halt()
    end

    def call(conn, _), do: conn |> send_resp(404, "") |> halt()

    defp serve(conn, "PUT", key) do
      {:ok, body, conn} = read_body(conn, length: 30_000_000)
      :ok = Mana.Storage.Local.put(key, body, "")
      conn |> put_resp_header("access-control-allow-origin", "*") |> send_resp(200, "") |> halt()
    end

    defp serve(conn, "GET", key) do
      if Mana.Storage.Local.exists?(key),
        do: conn |> put_resp_header("access-control-allow-origin", "*") |> send_file(200, Mana.Storage.Local.path(key)) |> halt(),
        else: conn |> send_resp(404, "") |> halt()
    end
  end
end

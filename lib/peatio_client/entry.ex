require Logger 

defmodule PeatioClient.Entry do
  use HTTPoison.Base
  use GenServer

  #############################################################################
  ### GenServer Callback
  #############################################################################

  def start_link(account, host, key \\ nil, secret \\ nil) do
    opts  = [name: account_name(account)]

    config = %{sign_request: sign_request(key, secret), host: host, key: key, secret: secret}
             |> Dict.merge build_request(host)

    GenServer.start_link(__MODULE__, config, opts)
  end

  def init(config) do
    {:ok, config}
  end

  def handle_call({:ticker, market}, _, state) do
    path = "/tickers/#{market}"
    body = state.build_get.(path) |> gogogo!

    {:reply, body, state} 
  end

  def handle_call({:trades, market, from}, _, state) do
    payload = [market: market]
    if from do payload = payload ++ [from: from] end

    body = state.build_get.("/trades")
            |> set_payload(payload)
            |> gogogo!

    {:reply, body, state} 
  end

  def handle_call(:members_accounts, _, state) do
    body = state.build_get.("/members/me")
            |> state.sign_request.()
            |> gogogo!

    {:reply, body, state} 
  end


  def handle_call(:members_me, _, state) do
    body = state.build_get.("/members/me")
            |> state.sign_request.()
            |> gogogo!

    {:reply, body, state}
  end

  def handle_call({:orders, market}, _, state) do
    body = state.build_get.("/orders")
            |> set_payload([market: market])
            |> state.sign_request.()
            |> gogogo!

    {:reply, body, state}
  end
  
  def handle_call({:order, order_id}, _, state) do
    body = state.build_get.("/order")
            |> set_payload([id: order_id])
            |> state.sign_request.()
            |> gogogo!

    {:reply, body, state}
  end

  def handle_call({:orders_multi, market, orders}, _, state) do
    orders = orders |> Enum.reduce [], fn
      (%{price: p, side: s, volume: v}, acc) -> 
        acc = acc ++ [{:"orders[][price]", p}]
        acc = acc ++ [{:"orders[][side]", s}]
        acc ++ [{:"orders[][volume]", v}]
    end

    body = state.build_post.("/orders/multi")
            |> set_multi(["orders[]": orders]) 
            |> set_payload([market: market])
            |> state.sign_request.()
            |> gogogo!

    {:reply, body, state}
  end

  def handle_call({:orders_cancel, side}, state) do
    do_orders_cancel(side, state)
    {:reply, :ok, state}
  end

  def handle_cast({:orders_cancel, id}, state) when is_integer(id) do
    state.build_post.("/order/delete")
    |> set_payload([id: id])
    |> state.sign_request.()
    |> gogogo!

    {:noreply, state}
  end

  def handle_cast({:orders_cancel, side}, state) do
    do_orders_cancel(side, state)
    {:noreply, state}
  end

  #############################################################################
  ### HTTPoison Callback and Helper
  #############################################################################

  defp process_response_body(body) do
    body |> Poison.decode!
  end

  #############################################################################
  ### Helper and Private
  #############################################################################

  defp do_orders_cancel(side, state) do
    payload = case side do
      :ask -> [side: "sell"]
      :bid -> [side: "buy"]
      _ -> []
    end

    state.build_post.("/orders/clear")
    |> set_payload(payload) 
    |> state.sign_request.()
    |> gogogo!

    case side do
      :ask -> log("CANCEL ASK ORDERS")
      :bid -> log("CANCEL BID ORDERS")
      _    -> log("CANCEL ALL ORDERS")
    end

    state
  end

  defp account_name(account) do
    String.to_atom "#{account}.api.peatio.com"
  end

  defp build_request(host) do
    build_get = fn(path) -> build_request(host, "/api/v2" <> path, :get) end
    build_post = fn(path) -> build_request(host, "/api/v2" <> path, :post) end
    %{build_get: build_get, build_post: build_post}
  end

  defp build_request(host, path, verb) when verb == :get or verb == :post do
    tonce = :os.system_time(:milli_seconds) 
    %{uri: host <> path, path: path, tonce: tonce, verb: verb, payload: nil, multi: [], timeout: 30000, retry: 3}
  end

  defp sign_request(nil, nil) do
    fn(_) -> raise "This client api is only for public." end
  end

  # REF: https://app.peatio.com/documents/api_v2#!/members/GET_version_members_me_format
  defp sign_request(key, secret) do
    fn(req) ->
      verb = req.verb |> Atom.to_string |> String.upcase

      payload = (req.payload || [])
                |> Dict.put(:access_key, key)
                |> Dict.put(:tonce, req.tonce)

      query = Enum.sort(payload ++ req.multi) |> Enum.map_join("&", &format_param/1)

      to_sign   = [verb, req.path, query] |> Enum.join("|")
      signature = :crypto.hmac(:sha256, secret, to_sign) |> Base.encode16 |> String.downcase

      payload = Dict.put(payload, :signature, signature)
      payload = req.multi |> Enum.reduce payload, fn ({_, v}, acc) -> acc ++ v end

      %{req | payload: payload}
    end
  end

  def set_payload(req = %{payload: nil}, payload) do
    %{req | payload: payload}
  end

  def set_payload(req = %{payload: payload}, new_payload) when is_list(payload) do
    %{req | payload: payload ++ new_payload}
  end

  def set_multi(req, multi) do
    %{req | multi: req.multi ++ multi}
  end

  defp format_param({_, v}) when is_list(v) do
    Enum.map_join v, "&", fn ({k, v}) -> "#{k}=#{v}" end
  end

  defp format_param({k, v}) do
    "#{k}=#{v}"
  end

  def gogogo!(%{retry: 0}) do
    Logger.error "RETRY END"
    raise "RETRY_END"
  end

  def gogogo!(req = %{uri: uri, verb: :get, payload: payload, timeout: timeout}) when is_list(payload) do
    Logger.debug "GET #{uri} #{inspect payload}"
    payload_str = payload |> Enum.map(fn({k, v}) -> "#{k}=#{v}" end) |> Enum.join("&")

    get(uri <> "?" <> payload_str, [], [{:timeout, timeout}])
    |> process_response(req)
  end

  def gogogo!(req = %{uri: uri, verb: :get, payload: _, timeout: timeout}) do
    Logger.debug "GET #{uri}"
    get(uri, [], [{:timeout, timeout}])
    |> process_response(req)
  end

  def gogogo!(req = %{uri: uri, verb: :post, payload: payload, timeout: timeout}) do
    Logger.debug "POST #{uri} #{inspect payload}"
    post(uri, {:form, payload}, [], [{:timeout, timeout}])
    |> process_response(req)
  end

  defp process_response(response, request) do
    case response do
      {:ok, %{status_code: 400, body: body}} ->
        err(body["error"])
        %{error: body["error"]["code"]}
      {:ok, %{body: body}} -> body
      {:error, reason} ->
        err("REQ ERROR #{reason}")
        gogogo!(%{request|retry: request.retry - 1})
    end
  end

  defp err(message, name \\ :api) do
    Logger.error "PEATIO CLIENT #{name}: #{message}" 
  end

  defp log(message, name \\ :api) do
    Logger.info "PEATIO CLIENT #{name}: #{inspect message}" 
  end
end


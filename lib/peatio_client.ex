defmodule PeatioClient do

  #############################################################################
  ### PEATIO Public API
  #############################################################################

  def ticker(account, market) do
    call(account, {:ticker, market}, fn body ->
      ticker = body |> Map.get("ticker") |> Enum.reduce %{}, fn
        ({key, val}, acc) ->
          key = key |> filter_key |> String.to_atom
          val = val |> Decimal.new
          Map.put(acc, key, val)
      end
      Map.put ticker, :at, body["at"]
    end)
  end

  def trades(api, market, from \\ nil) do
    call(api, {:trades, market, from}, fn body ->
      body |> Enum.map &convert_trade/1
    end)
  end

  #############################################################################
  ### PEATIO Private API
  #############################################################################

  def me(api) do
    call(api, :members_me)
  end

  def accounts(api) do
    call(api, :members_me, fn member_info ->
      member_info["accounts"] |> Enum.reduce(%{}, fn account, acc ->
        locked = Decimal.new(account["locked"])
        balance = Decimal.new(account["balance"])
        amount = Decimal.add(locked, balance)
        asset = String.to_atom account["currency"]
        account = %{asset: asset, balance: balance, locked: locked, amount: amount}
        Dict.put acc, asset, account
      end)
    end)
  end

  def bid(api, market, orders) do
    orders = orders |> Enum.map fn {p, v} -> {:bid, p, v} end
    entry_orders(api, market, orders)
  end

  def ask(api, market, orders) do
    orders = orders |> Enum.map fn {p, v} -> {:ask, p, v} end
    entry_orders(api, market, orders)
  end

  def entry_orders(api, market, orders) do
    orders = orders |> Enum.map fn
      ({:ask, price, volume}) ->
        %{price: price, side: :sell, volume: volume}
      ({:bid, price, volume}) ->
        %{price: price, side: :buy, volume: volume}
    end

    call(api, {:orders_multi, market, orders}, fn orders ->
      orders |> Enum.map(&convert_order/1)
    end)
  end

  def orders(api, market) do
    call(api, {:orders, market}, fn orders ->
      orders |> Enum.map(&convert_order/1)
    end)
  end

  def order(api, order_id) do
    call(api, {:order, order_id}, fn order ->
      order |> convert_order
    end)
  end

  def cancel(api, id, way \\ :sync) when is_integer(id) do
    do_cancel(api, id, way)
  end

  def cancel_all(api, way \\ :sync) do
    do_cancel(api, :all, way)
  end

  def cancel_ask(api, way \\ :sync) do
    do_cancel(api, :ask, way)
  end

  def cancel_bid(api, way \\ :sync) do
    do_cancel(api, :bid, way)
  end

  defp do_cancel(api, payload, way) do
    case way do
      :sync -> call(api, {:orders_cancel, payload})
      :async -> cast(api, {:orders_cancel, payload})
    end
  end

  defp empty_callback(r), do: r

  defp callback(:ok, callback),              do: callback.(:ok)
  defp callback({:ok, data}, callback),      do: callback.(data)
  defp callback({:error, error}, _callback), do: error

  defp call(api, payload, callback \\ &empty_callback/1) do
    GenServer.call(entry_id(api), payload, :infinity) |> callback(callback)
  end

  defp cast(api, payload) do
    GenServer.cast(entry_id(api), payload)
  end

  #############################################################################

  defp filter_key(key) do
    case key do
      "buy"  -> "bid"
      "sell" -> "ask"
      _      -> key
    end
  end

  defp filter_order_val(key, val) do
    case key do
      "avg_price" -> Decimal.new(val)
      "price" -> Decimal.new(val)
      "executed_volume" -> Decimal.new(val)
      "remaining_volume" -> Decimal.new(val)
      "volume" -> Decimal.new(val)
      "side" -> String.to_atom(filter_key(val))
      "market" -> String.to_atom(val)
      "state" -> String.to_atom(val)
      _ -> val
    end
  end

  defp convert_order(order) when is_map(order) do
    for {key, val} <- order, into: %{}, do: {String.to_atom(key), filter_order_val(key, val)}
  end

  defp convert_trade(trade) do
    %{
      id: trade["id"], 
      at: trade["at"], 
      price: Decimal.new(trade["price"]), 
      volume: Decimal.new(trade["volume"]),
      side: String.to_atom(trade["side"]),
      funds: Decimal.new(trade["funds"])
    }
  end

  defp entry_id(api) do
    String.to_atom "#{api}.peatio.com"
  end
end

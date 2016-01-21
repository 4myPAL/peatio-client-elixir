defmodule PeatioClient do

  #############################################################################
  ### PEATIO Public API
  #############################################################################

  def ticker(account, market) do
    body = call(account, {:ticker, market})

    ticker = body |> Map.get("ticker") |> Enum.reduce %{}, fn
      ({key, val}, acc) ->
        key = key |> filter_key |> String.to_atom
        val = val |> Decimal.new
        Map.put(acc, key, val)
    end
    Map.put ticker, :at, body["at"]
  end

  def trades(api, market, from \\ nil) do
    call(api, {:trades, market, from})
    |> Enum.map &convert_trade/1
  end

  #############################################################################
  ### PEATIO Private API
  #############################################################################

  def me(api) do
    call(api, :members_me)
  end

  def accounts(api) do
    member_info = call(api, :members_me)
    member_info["accounts"] |> Enum.reduce(%{}, fn account, acc ->
      locked = Decimal.new(account["locked"])
      balance = Decimal.new(account["balance"])
      amount = Decimal.add(locked, balance)
      asset = String.to_atom account["currency"]
      account = %{asset: asset, balance: balance, locked: locked, amount: amount}
      Dict.put acc, asset, account
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

    case call(api, {:orders_multi, market, orders}) do
      response = %{error: _} -> response
      body -> Enum.map(body, &convert_order/1)
    end
  end

  def orders(api, market) do
    call(api, {:orders, market})
    |> Enum.map &convert_order/1
  end

  def order(api, order_id) do
    call(api, {:order, order_id})
    |> convert_order
  end

  def cancel(api, id) when is_integer(id) do
    cast(api, {:orders_cancel, id})
  end

  def cancel_all(api) do
    cast(api, {:orders_cancel, :all})
  end

  def cancel_ask(api) do
    cast(api, {:orders_cancel, :ask})
  end

  def cancel_bid(api) do
    cast(api, {:orders_cancel, :bid})
  end

  def cancel_all_async(api) do
    call(api, {:orders_cancel, :all})
  end

  def cancel_ask_async(api) do
    call(api, {:orders_cancel, :ask})
  end

  def cancel_bid_async(api) do
    call(api, {:orders_cancel, :bid})
  end

  defp call(api, payload) do
    GenServer.call(entry_id(api), payload, :infinity)
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

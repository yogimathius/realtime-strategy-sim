defmodule RealtimeStrategySim.Economic.MarketSystem do
  @moduledoc """
  Multi-resource economic simulation with dynamic pricing and trade networks.
  
  The MarketSystem manages:
  - Supply and demand dynamics for multiple resources
  - Dynamic pricing based on market conditions
  - Player-to-player trading and auction systems
  - Economic warfare mechanics (blockades, market manipulation)
  - Automated trading bots and market makers
  """
  
  use GenServer
  require Logger

  @resources [:minerals, :gas, :energy, :food, :research_points, :rare_metals]
  @default_base_prices %{
    minerals: 1.0,
    gas: 1.5,
    energy: 0.8,
    food: 0.6,
    research_points: 3.0,
    rare_metals: 8.0
  }
  
  @type resource_type :: atom()
  @type player_id :: String.t()
  @type trade_order :: %{
    id: String.t(),
    player_id: player_id(),
    resource: resource_type(),
    quantity: integer(),
    price_per_unit: float(),
    order_type: :buy | :sell,
    created_at: integer(),
    expires_at: integer()
  }
  
  @type market_state :: %{
    resource_prices: %{resource_type() => float()},
    order_book: %{resource_type() => %{buy_orders: [trade_order()], sell_orders: [trade_order()]}},
    trade_history: [map()],
    market_stats: %{resource_type() => map()},
    player_portfolios: %{player_id() => %{resource_type() => integer()}},
    trading_bots: [pid()],
    market_events: [map()]
  }

  # Client API

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get_resource_price(resource_type()) :: {:ok, float()} | {:error, :invalid_resource}
  def get_resource_price(resource) do
    GenServer.call(__MODULE__, {:get_resource_price, resource})
  end

  @spec get_market_stats() :: map()
  def get_market_stats do
    GenServer.call(__MODULE__, :get_market_stats)
  end

  @spec place_buy_order(player_id(), resource_type(), integer(), float()) :: {:ok, String.t()} | {:error, term()}
  def place_buy_order(player_id, resource, quantity, price_per_unit) do
    GenServer.call(__MODULE__, {:place_buy_order, player_id, resource, quantity, price_per_unit})
  end

  @spec place_sell_order(player_id(), resource_type(), integer(), float()) :: {:ok, String.t()} | {:error, term()}
  def place_sell_order(player_id, resource, quantity, price_per_unit) do
    GenServer.call(__MODULE__, {:place_sell_order, player_id, resource, quantity, price_per_unit})
  end

  @spec cancel_order(String.t()) :: :ok | {:error, :order_not_found}
  def cancel_order(order_id) do
    GenServer.call(__MODULE__, {:cancel_order, order_id})
  end

  @spec get_player_portfolio(player_id()) :: %{resource_type() => integer()}
  def get_player_portfolio(player_id) do
    GenServer.call(__MODULE__, {:get_player_portfolio, player_id})
  end

  @spec transfer_resources(player_id(), player_id(), resource_type(), integer()) :: :ok | {:error, term()}
  def transfer_resources(from_player, to_player, resource, quantity) do
    GenServer.call(__MODULE__, {:transfer_resources, from_player, to_player, resource, quantity})
  end

  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Market manipulation and economic warfare
  @spec create_blockade(player_id(), resource_type(), float()) :: {:ok, String.t()} | {:error, term()}
  def create_blockade(player_id, resource, price_impact) do
    GenServer.call(__MODULE__, {:create_blockade, player_id, resource, price_impact})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("MarketSystem starting up")
    
    state = %{
      resource_prices: @default_base_prices,
      order_book: initialize_order_book(),
      trade_history: [],
      market_stats: initialize_market_stats(),
      player_portfolios: %{},
      trading_bots: [],
      market_events: []
    }
    
    # Start market simulation processes
    start_market_makers()
    schedule_market_updates()
    
    {:ok, state}
  end

  @impl true
  def handle_call({:get_resource_price, resource}, _from, state) do
    case Map.get(state.resource_prices, resource) do
      nil ->
        {:reply, {:error, :invalid_resource}, state}
      price ->
        {:reply, {:ok, price}, state}
    end
  end

  @impl true
  def handle_call(:get_market_stats, _from, state) do
    current_stats = calculate_market_stats(state)
    {:reply, current_stats, state}
  end

  @impl true
  def handle_call({:place_buy_order, player_id, resource, quantity, price_per_unit}, _from, state) do
    if valid_resource?(resource) and quantity > 0 and price_per_unit > 0 do
      order_id = generate_order_id()
      order = %{
        id: order_id,
        player_id: player_id,
        resource: resource,
        quantity: quantity,
        price_per_unit: price_per_unit,
        order_type: :buy,
        created_at: :os.system_time(:millisecond),
        expires_at: :os.system_time(:millisecond) + 3_600_000 # 1 hour
      }
      
      # Try to match with existing sell orders first
      {updated_state, matches} = match_buy_order(state, order)
      
      # Add remaining order to order book if not fully matched
      final_state = if order.quantity > 0 do
        add_order_to_book(updated_state, order)
      else
        updated_state
      end
      
      # Process any matched trades
      processed_state = process_trade_matches(final_state, matches)
      
      Logger.info("Buy order placed: #{player_id} wants #{quantity} #{resource} at #{price_per_unit}")
      {:reply, {:ok, order_id}, processed_state}
    else
      {:reply, {:error, :invalid_order}, state}
    end
  end

  @impl true
  def handle_call({:place_sell_order, player_id, resource, quantity, price_per_unit}, _from, state) do
    if valid_resource?(resource) and quantity > 0 and price_per_unit > 0 do
      # Check if player has enough resources
      portfolio = Map.get(state.player_portfolios, player_id, %{})
      available = Map.get(portfolio, resource, 0)
      
      if available >= quantity do
        order_id = generate_order_id()
        order = %{
          id: order_id,
          player_id: player_id,
          resource: resource,
          quantity: quantity,
          price_per_unit: price_per_unit,
          order_type: :sell,
          created_at: :os.system_time(:millisecond),
          expires_at: :os.system_time(:millisecond) + 3_600_000 # 1 hour
        }
        
        # Reserve resources from player's portfolio
        updated_portfolio = Map.put(portfolio, resource, available - quantity)
        updated_portfolios = Map.put(state.player_portfolios, player_id, updated_portfolio)
        
        state_with_reserved = %{state | player_portfolios: updated_portfolios}
        
        # Try to match with existing buy orders
        {updated_state, matches} = match_sell_order(state_with_reserved, order)
        
        # Add remaining order to order book if not fully matched
        final_state = if order.quantity > 0 do
          add_order_to_book(updated_state, order)
        else
          updated_state
        end
        
        # Process any matched trades
        processed_state = process_trade_matches(final_state, matches)
        
        Logger.info("Sell order placed: #{player_id} selling #{quantity} #{resource} at #{price_per_unit}")
        {:reply, {:ok, order_id}, processed_state}
      else
        {:reply, {:error, :insufficient_resources}, state}
      end
    else
      {:reply, {:error, :invalid_order}, state}
    end
  end

  @impl true
  def handle_call({:cancel_order, order_id}, _from, state) do
    case find_and_remove_order(state, order_id) do
      {:ok, updated_state, canceled_order} ->
        # Return reserved resources if it was a sell order
        final_state = if canceled_order.order_type == :sell do
          return_reserved_resources(updated_state, canceled_order)
        else
          updated_state
        end
        
        Logger.info("Order #{order_id} canceled")
        {:reply, :ok, final_state}
        
      {:error, :not_found} ->
        {:reply, {:error, :order_not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_player_portfolio, player_id}, _from, state) do
    portfolio = Map.get(state.player_portfolios, player_id, initialize_player_portfolio())
    {:reply, portfolio, state}
  end

  @impl true
  def handle_call({:transfer_resources, from_player, to_player, resource, quantity}, _from, state) do
    from_portfolio = Map.get(state.player_portfolios, from_player, %{})
    from_available = Map.get(from_portfolio, resource, 0)
    
    if from_available >= quantity do
      # Update sender's portfolio
      updated_from_portfolio = Map.put(from_portfolio, resource, from_available - quantity)
      
      # Update receiver's portfolio
      to_portfolio = Map.get(state.player_portfolios, to_player, initialize_player_portfolio())
      to_available = Map.get(to_portfolio, resource, 0)
      updated_to_portfolio = Map.put(to_portfolio, resource, to_available + quantity)
      
      # Update state
      updated_portfolios = state.player_portfolios
      |> Map.put(from_player, updated_from_portfolio)
      |> Map.put(to_player, updated_to_portfolio)
      
      updated_state = %{state | player_portfolios: updated_portfolios}
      
      Logger.info("Transferred #{quantity} #{resource} from #{from_player} to #{to_player}")
      {:reply, :ok, updated_state}
    else
      {:reply, {:error, :insufficient_resources}, state}
    end
  end

  @impl true
  def handle_call({:create_blockade, player_id, resource, price_impact}, _from, state) do
    blockade_id = generate_blockade_id()
    
    # Create market event for blockade
    event = %{
      id: blockade_id,
      type: :blockade,
      player_id: player_id,
      resource: resource,
      price_impact: price_impact,
      created_at: :os.system_time(:millisecond),
      duration_ms: 300_000 # 5 minutes
    }
    
    updated_events = [event | state.market_events]
    
    # Apply immediate price impact
    current_price = Map.get(state.resource_prices, resource, 1.0)
    new_price = current_price * (1.0 + price_impact)
    updated_prices = Map.put(state.resource_prices, resource, new_price)
    
    updated_state = %{state |
      market_events: updated_events,
      resource_prices: updated_prices
    }
    
    Logger.warning("Economic blockade created on #{resource} by #{player_id}, price impact: #{price_impact * 100}%")
    {:reply, {:ok, blockade_id}, updated_state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      resource_prices: state.resource_prices,
      total_orders: count_total_orders(state.order_book),
      trade_volume_24h: calculate_trade_volume(state.trade_history),
      active_players: map_size(state.player_portfolios),
      market_events: length(state.market_events),
      trading_bots: length(state.trading_bots)
    }
    
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:market_update, state) do
    Logger.debug("Running market update cycle")
    
    # Update prices based on supply and demand
    updated_state = update_market_prices(state)
    
    # Clean up expired orders
    cleaned_state = clean_expired_orders(updated_state)
    
    # Clean up expired market events
    final_state = clean_expired_events(cleaned_state)
    
    # Schedule next market update
    schedule_market_updates()
    
    {:noreply, final_state}
  end

  @impl true
  def handle_info(:bot_trade, state) do
    # Simulate automated trading bot activity
    updated_state = execute_bot_trades(state)
    
    # Schedule next bot trading cycle
    Process.send_after(self(), :bot_trade, 5_000 + :rand.uniform(10_000)) # 5-15 seconds
    
    {:noreply, updated_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("MarketSystem received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("MarketSystem terminating: #{inspect(reason)}")
    :ok
  end

  # Private Helper Functions

  defp initialize_order_book do
    @resources
    |> Enum.map(fn resource ->
      {resource, %{buy_orders: [], sell_orders: []}}
    end)
    |> Map.new()
  end

  defp initialize_market_stats do
    @resources
    |> Enum.map(fn resource ->
      {resource, %{
        volume_24h: 0,
        price_change_24h: 0.0,
        high_24h: Map.get(@default_base_prices, resource),
        low_24h: Map.get(@default_base_prices, resource),
        last_trade_price: Map.get(@default_base_prices, resource)
      }}
    end)
    |> Map.new()
  end

  defp initialize_player_portfolio do
    # New players start with basic resources
    %{
      minerals: 1000,
      gas: 500,
      energy: 100,
      food: 200,
      research_points: 0,
      rare_metals: 0
    }
  end

  defp valid_resource?(resource) do
    resource in @resources
  end

  defp generate_order_id do
    "order_" <> Base.encode16(:crypto.strong_rand_bytes(8))
  end

  defp generate_blockade_id do
    "blockade_" <> Base.encode16(:crypto.strong_rand_bytes(6))
  end

  defp match_buy_order(state, buy_order) do
    resource_orders = Map.get(state.order_book, buy_order.resource)
    sell_orders = Map.get(resource_orders, :sell_orders, [])
    
    # Find matching sell orders (price <= buy price)
    matching_orders = sell_orders
    |> Enum.filter(&(&1.price_per_unit <= buy_order.price_per_unit))
    |> Enum.sort_by(&{&1.price_per_unit, &1.created_at}) # Best price first, then FIFO
    
    process_order_matches(state, buy_order, matching_orders, [])
  end

  defp match_sell_order(state, sell_order) do
    resource_orders = Map.get(state.order_book, sell_order.resource)
    buy_orders = Map.get(resource_orders, :buy_orders, [])
    
    # Find matching buy orders (price >= sell price)
    matching_orders = buy_orders
    |> Enum.filter(&(&1.price_per_unit >= sell_order.price_per_unit))
    |> Enum.sort_by(&{-&1.price_per_unit, &1.created_at}) # Best price first, then FIFO
    
    process_order_matches(state, sell_order, matching_orders, [])
  end

  defp process_order_matches(state, _order, [], matches) do
    {state, matches}
  end

  defp process_order_matches(state, order, [match_order | remaining], matches) do
    if order.quantity <= 0 do
      {state, matches}
    else
      trade_quantity = min(order.quantity, match_order.quantity)
      trade_price = match_order.price_per_unit # Use the matched order's price
      
      # Create trade record
      trade = %{
        buy_order_id: if(order.order_type == :buy, do: order.id, else: match_order.id),
        sell_order_id: if(order.order_type == :sell, do: order.id, else: match_order.id),
        resource: order.resource,
        quantity: trade_quantity,
        price_per_unit: trade_price,
        timestamp: :os.system_time(:millisecond)
      }
      
      # Update order quantities
      updated_order = %{order | quantity: order.quantity - trade_quantity}
      updated_match_order = %{match_order | quantity: match_order.quantity - trade_quantity}
      
      # Update state to remove fully filled orders
      updated_state = if updated_match_order.quantity <= 0 do
        remove_order_from_book(state, match_order)
      else
        update_order_in_book(state, updated_match_order)
      end
      
      # Continue matching with remaining orders
      process_order_matches(updated_state, updated_order, remaining, [trade | matches])
    end
  end

  defp add_order_to_book(state, order) do
    resource_orders = Map.get(state.order_book, order.resource)
    
    updated_orders = case order.order_type do
      :buy ->
        buy_orders = [order | Map.get(resource_orders, :buy_orders, [])]
        |> Enum.sort_by(&{-&1.price_per_unit, &1.created_at}) # Highest price first
        Map.put(resource_orders, :buy_orders, buy_orders)
        
      :sell ->
        sell_orders = [order | Map.get(resource_orders, :sell_orders, [])]
        |> Enum.sort_by(&{&1.price_per_unit, &1.created_at}) # Lowest price first
        Map.put(resource_orders, :sell_orders, sell_orders)
    end
    
    updated_order_book = Map.put(state.order_book, order.resource, updated_orders)
    %{state | order_book: updated_order_book}
  end

  defp remove_order_from_book(state, order) do
    resource_orders = Map.get(state.order_book, order.resource)
    
    updated_orders = case order.order_type do
      :buy ->
        buy_orders = Enum.reject(Map.get(resource_orders, :buy_orders, []), &(&1.id == order.id))
        Map.put(resource_orders, :buy_orders, buy_orders)
        
      :sell ->
        sell_orders = Enum.reject(Map.get(resource_orders, :sell_orders, []), &(&1.id == order.id))
        Map.put(resource_orders, :sell_orders, sell_orders)
    end
    
    updated_order_book = Map.put(state.order_book, order.resource, updated_orders)
    %{state | order_book: updated_order_book}
  end

  defp update_order_in_book(state, updated_order) do
    # Remove the old order and add the updated one
    state
    |> remove_order_from_book(updated_order)
    |> add_order_to_book(updated_order)
  end

  defp process_trade_matches(state, trades) do
    # Process all completed trades
    Enum.reduce(trades, state, fn trade, acc_state ->
      process_single_trade(acc_state, trade)
    end)
  end

  defp process_single_trade(state, trade) do
    # Add to trade history
    updated_history = [trade | Enum.take(state.trade_history, 999)] # Keep last 1000 trades
    
    # Update market stats
    updated_stats = update_trade_stats(state.market_stats, trade)
    
    # Update resource prices based on trade
    updated_prices = update_price_from_trade(state.resource_prices, trade)
    
    %{state |
      trade_history: updated_history,
      market_stats: updated_stats,
      resource_prices: updated_prices
    }
  end

  defp find_and_remove_order(state, order_id) do
    # Search through all resources and order types
    Enum.reduce_while(@resources, {:error, :not_found}, fn resource, _acc ->
      resource_orders = Map.get(state.order_book, resource)
      
      # Check buy orders
      case Enum.find(Map.get(resource_orders, :buy_orders, []), &(&1.id == order_id)) do
        nil ->
          # Check sell orders
          case Enum.find(Map.get(resource_orders, :sell_orders, []), &(&1.id == order_id)) do
            nil -> {:cont, {:error, :not_found}}
            order -> 
              updated_state = remove_order_from_book(state, order)
              {:halt, {:ok, updated_state, order}}
          end
        order ->
          updated_state = remove_order_from_book(state, order)
          {:halt, {:ok, updated_state, order}}
      end
    end)
  end

  defp return_reserved_resources(state, canceled_order) do
    portfolio = Map.get(state.player_portfolios, canceled_order.player_id, %{})
    current = Map.get(portfolio, canceled_order.resource, 0)
    updated_portfolio = Map.put(portfolio, canceled_order.resource, current + canceled_order.quantity)
    updated_portfolios = Map.put(state.player_portfolios, canceled_order.player_id, updated_portfolio)
    
    %{state | player_portfolios: updated_portfolios}
  end

  defp calculate_market_stats(state) do
    %{
      total_orders: count_total_orders(state.order_book),
      trade_volume: length(state.trade_history),
      resource_prices: state.resource_prices,
      active_players: map_size(state.player_portfolios),
      market_events: length(state.market_events)
    }
  end

  defp count_total_orders(order_book) do
    order_book
    |> Enum.reduce(0, fn {_resource, orders}, acc ->
      buy_count = length(Map.get(orders, :buy_orders, []))
      sell_count = length(Map.get(orders, :sell_orders, []))
      acc + buy_count + sell_count
    end)
  end

  defp calculate_trade_volume(trade_history) do
    # Calculate last 24 hours of trade volume
    cutoff_time = :os.system_time(:millisecond) - 86_400_000 # 24 hours
    
    trade_history
    |> Enum.filter(&(&1.timestamp >= cutoff_time))
    |> Enum.reduce(0, &(&2 + &1.quantity * &1.price_per_unit))
  end

  defp update_trade_stats(market_stats, trade) do
    resource = trade.resource
    current_stats = Map.get(market_stats, resource, %{})
    
    updated_resource_stats = %{current_stats |
      volume_24h: Map.get(current_stats, :volume_24h, 0) + trade.quantity,
      last_trade_price: trade.price_per_unit,
      high_24h: max(Map.get(current_stats, :high_24h, trade.price_per_unit), trade.price_per_unit),
      low_24h: min(Map.get(current_stats, :low_24h, trade.price_per_unit), trade.price_per_unit)
    }
    
    Map.put(market_stats, resource, updated_resource_stats)
  end

  defp update_price_from_trade(prices, trade) do
    # Simple price discovery - trades influence market price
    current_price = Map.get(prices, trade.resource, 1.0)
    price_influence = 0.01 # 1% influence per trade
    
    new_price = current_price * (1.0 + price_influence * (trade.price_per_unit / current_price - 1.0))
    Map.put(prices, trade.resource, new_price)
  end

  defp update_market_prices(state) do
    # Simulate market price movements based on supply/demand
    updated_prices = @resources
    |> Enum.reduce(state.resource_prices, fn resource, prices ->
      current_price = Map.get(prices, resource)
      
      # Calculate supply/demand ratio
      resource_orders = Map.get(state.order_book, resource)
      buy_volume = calculate_order_volume(Map.get(resource_orders, :buy_orders, []))
      sell_volume = calculate_order_volume(Map.get(resource_orders, :sell_orders, []))
      
      # Apply random market volatility (±2%)
      volatility = (:rand.uniform() - 0.5) * 0.04
      
      # Apply supply/demand pressure
      supply_demand_factor = if buy_volume + sell_volume > 0 do
        (buy_volume - sell_volume) / (buy_volume + sell_volume) * 0.01
      else
        0
      end
      
      new_price = current_price * (1.0 + volatility + supply_demand_factor)
      new_price = max(new_price, 0.1) # Minimum price floor
      
      Map.put(prices, resource, new_price)
    end)
    
    %{state | resource_prices: updated_prices}
  end

  defp calculate_order_volume(orders) do
    Enum.reduce(orders, 0, &(&2 + &1.quantity))
  end

  defp clean_expired_orders(state) do
    current_time = :os.system_time(:millisecond)
    
    updated_order_book = @resources
    |> Enum.reduce(state.order_book, fn resource, order_book ->
      resource_orders = Map.get(order_book, resource)
      
      # Filter out expired orders
      active_buy_orders = Map.get(resource_orders, :buy_orders, [])
      |> Enum.filter(&(&1.expires_at > current_time))
      
      active_sell_orders = Map.get(resource_orders, :sell_orders, [])
      |> Enum.filter(&(&1.expires_at > current_time))
      
      updated_resource_orders = %{
        buy_orders: active_buy_orders,
        sell_orders: active_sell_orders
      }
      
      Map.put(order_book, resource, updated_resource_orders)
    end)
    
    %{state | order_book: updated_order_book}
  end

  defp clean_expired_events(state) do
    current_time = :os.system_time(:millisecond)
    
    active_events = state.market_events
    |> Enum.filter(fn event ->
      event.created_at + Map.get(event, :duration_ms, 300_000) > current_time
    end)
    
    %{state | market_events: active_events}
  end

  defp execute_bot_trades(state) do
    # Simple trading bot that adds liquidity to the market
    if :rand.uniform() < 0.3 do # 30% chance of bot activity each cycle
      resource = Enum.random(@resources)
      current_price = Map.get(state.resource_prices, resource)
      
      bot_id = "trading_bot_" <> Integer.to_string(:rand.uniform(10))
      
      # Ensure bot has resources in portfolio
      portfolio = Map.get(state.player_portfolios, bot_id, initialize_player_portfolio())
      updated_portfolios = Map.put(state.player_portfolios, bot_id, portfolio)
      
      # Place random order
      if :rand.uniform() < 0.5 do
        # Buy order slightly below market price
        quantity = :rand.uniform(100) + 10
        price = current_price * (0.95 + :rand.uniform() * 0.05) # 95-100% of market price
        
        order = %{
          id: generate_order_id(),
          player_id: bot_id,
          resource: resource,
          quantity: quantity,
          price_per_unit: price,
          order_type: :buy,
          created_at: :os.system_time(:millisecond),
          expires_at: :os.system_time(:millisecond) + 1_800_000 # 30 minutes
        }
        
        state_with_bot = %{state | player_portfolios: updated_portfolios}
        add_order_to_book(state_with_bot, order)
      else
        # Sell order slightly above market price
        available = Map.get(portfolio, resource, 0)
        
        if available > 10 do
          quantity = min(:rand.uniform(50) + 5, available)
          price = current_price * (1.0 + :rand.uniform() * 0.05) # 100-105% of market price
          
          order = %{
            id: generate_order_id(),
            player_id: bot_id,
            resource: resource,
            quantity: quantity,
            price_per_unit: price,
            order_type: :sell,
            created_at: :os.system_time(:millisecond),
            expires_at: :os.system_time(:millisecond) + 1_800_000 # 30 minutes
          }
          
          # Reserve resources
          updated_portfolio = Map.put(portfolio, resource, available - quantity)
          final_portfolios = Map.put(updated_portfolios, bot_id, updated_portfolio)
          
          state_with_bot = %{state | player_portfolios: final_portfolios}
          add_order_to_book(state_with_bot, order)
        else
          %{state | player_portfolios: updated_portfolios}
        end
      end
    else
      state
    end
  end

  defp start_market_makers do
    Logger.info("Starting automated market maker bots")
    Process.send_after(self(), :bot_trade, 10_000) # Start bot trading in 10 seconds
  end

  defp schedule_market_updates do
    Process.send_after(self(), :market_update, 5_000) # Every 5 seconds
  end
end
defmodule RealtimeStrategySim.AI.DecisionEngine do
  @moduledoc """
  Advanced AI system for strategic planning and unit behavior.
  
  The DecisionEngine provides:
  - Individual unit AI with behavior trees and state machines
  - Strategic AI for base management and long-term planning
  - Diplomatic AI for alliance formation and negotiation
  - Economic AI for trade decisions and market manipulation
  - Learning and adaptation based on combat experience
  """
  
  use GenServer
  require Logger

  alias RealtimeStrategySim.{
    Entity.EntitySupervisor,
    Economic.MarketSystem,
    Military.CombatEngine,
    World.WorldManager
  }

  @unit_states [:idle, :moving, :attacking, :defending, :retreating, :repairing, :scouting]
  @strategic_goals [:expand, :defend, :economic_growth, :military_buildup, :research, :diplomacy]
  @personality_traits [:aggressive, :defensive, :economic, :expansionist, :diplomatic, :unpredictable]
  
  @type entity_id :: String.t()
  @type player_id :: String.t()
  @type position :: {float(), float()}
  @type unit_state :: atom()
  @type strategic_goal :: atom()
  @type personality :: atom()
  
  @type behavior_tree_node :: %{
    type: :selector | :sequence | :condition | :action,
    children: [behavior_tree_node()] | nil,
    condition: function() | nil,
    action: function() | nil,
    status: :running | :success | :failure | :ready
  }
  
  @type unit_ai :: %{
    entity_id: entity_id(),
    current_state: unit_state(),
    behavior_tree: behavior_tree_node(),
    target: entity_id() | nil,
    last_decision: integer(),
    experience: %{
      kills: integer(),
      deaths: integer(),
      damage_dealt: integer(),
      damage_received: integer()
    },
    personality_traits: [personality()]
  }
  
  @type strategic_ai :: %{
    player_id: player_id(),
    primary_goal: strategic_goal(),
    secondary_goals: [strategic_goal()],
    resource_priorities: %{atom() => float()},
    threat_assessment: %{player_id() => float()},
    diplomatic_status: %{player_id() => :ally | :neutral | :enemy},
    last_strategy_update: integer()
  }
  
  @type ai_state :: %{
    unit_ais: %{entity_id() => unit_ai()},
    strategic_ais: %{player_id() => strategic_ai()},
    global_knowledge: %{
      resource_locations: [position()],
      enemy_positions: %{entity_id() => position()},
      strategic_locations: [position()]
    },
    learning_data: %{
      successful_strategies: [map()],
      failed_strategies: [map()],
      adaptation_rate: float()
    }
  }

  # Client API

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register_unit_ai(entity_id(), map()) :: :ok
  def register_unit_ai(entity_id, ai_config) do
    GenServer.call(__MODULE__, {:register_unit_ai, entity_id, ai_config})
  end

  @spec unregister_unit_ai(entity_id()) :: :ok
  def unregister_unit_ai(entity_id) do
    GenServer.call(__MODULE__, {:unregister_unit_ai, entity_id})
  end

  @spec register_strategic_ai(player_id(), map()) :: :ok
  def register_strategic_ai(player_id, strategy_config) do
    GenServer.call(__MODULE__, {:register_strategic_ai, player_id, strategy_config})
  end

  @spec get_unit_decision(entity_id()) :: {:ok, map()} | {:error, :not_found}
  def get_unit_decision(entity_id) do
    GenServer.call(__MODULE__, {:get_unit_decision, entity_id})
  end

  @spec get_strategic_decision(player_id()) :: {:ok, map()} | {:error, :not_found}
  def get_strategic_decision(player_id) do
    GenServer.call(__MODULE__, {:get_strategic_decision, player_id})
  end

  @spec update_unit_experience(entity_id(), map()) :: :ok
  def update_unit_experience(entity_id, experience_data) do
    GenServer.cast(__MODULE__, {:update_unit_experience, entity_id, experience_data})
  end

  @spec set_diplomatic_status(player_id(), player_id(), atom()) :: :ok
  def set_diplomatic_status(player_id, target_player_id, status) do
    GenServer.call(__MODULE__, {:set_diplomatic_status, player_id, target_player_id, status})
  end

  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("DecisionEngine starting up")
    
    state = %{
      unit_ais: %{},
      strategic_ais: %{},
      global_knowledge: %{
        resource_locations: generate_resource_locations(),
        enemy_positions: %{},
        strategic_locations: generate_strategic_locations()
      },
      learning_data: %{
        successful_strategies: [],
        failed_strategies: [],
        adaptation_rate: 0.1
      }
    }
    
    # Schedule AI processing
    schedule_ai_updates()
    
    {:ok, state}
  end

  @impl true
  def handle_call({:register_unit_ai, entity_id, ai_config}, _from, state) do
    unit_ai = create_unit_ai(entity_id, ai_config)
    updated_unit_ais = Map.put(state.unit_ais, entity_id, unit_ai)
    updated_state = %{state | unit_ais: updated_unit_ais}
    
    Logger.info("Registered unit AI for #{entity_id} with traits: #{inspect(unit_ai.personality_traits)}")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:unregister_unit_ai, entity_id}, _from, state) do
    updated_unit_ais = Map.delete(state.unit_ais, entity_id)
    updated_state = %{state | unit_ais: updated_unit_ais}
    
    Logger.info("Unregistered unit AI for #{entity_id}")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:register_strategic_ai, player_id, strategy_config}, _from, state) do
    strategic_ai = create_strategic_ai(player_id, strategy_config)
    updated_strategic_ais = Map.put(state.strategic_ais, player_id, strategic_ai)
    updated_state = %{state | strategic_ais: updated_strategic_ais}
    
    Logger.info("Registered strategic AI for player #{player_id} with goal: #{strategic_ai.primary_goal}")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call({:get_unit_decision, entity_id}, _from, state) do
    case Map.get(state.unit_ais, entity_id) do
      nil ->
        {:reply, {:error, :not_found}, state}
        
      unit_ai ->
        decision = execute_unit_behavior_tree(unit_ai, state)
        updated_unit_ai = %{unit_ai | last_decision: :os.system_time(:millisecond)}
        updated_unit_ais = Map.put(state.unit_ais, entity_id, updated_unit_ai)
        updated_state = %{state | unit_ais: updated_unit_ais}
        
        Logger.debug("Unit #{entity_id} decision: #{inspect(decision)}")
        {:reply, {:ok, decision}, updated_state}
    end
  end

  @impl true
  def handle_call({:get_strategic_decision, player_id}, _from, state) do
    case Map.get(state.strategic_ais, player_id) do
      nil ->
        {:reply, {:error, :not_found}, state}
        
      strategic_ai ->
        decision = execute_strategic_planning(strategic_ai, state)
        updated_strategic_ai = %{strategic_ai | last_strategy_update: :os.system_time(:millisecond)}
        updated_strategic_ais = Map.put(state.strategic_ais, player_id, updated_strategic_ai)
        updated_state = %{state | strategic_ais: updated_strategic_ais}
        
        Logger.info("Player #{player_id} strategic decision: #{inspect(decision)}")
        {:reply, {:ok, decision}, updated_state}
    end
  end

  @impl true
  def handle_call({:set_diplomatic_status, player_id, target_player_id, status}, _from, state) do
    case Map.get(state.strategic_ais, player_id) do
      nil ->
        {:reply, {:error, :player_not_found}, state}
        
      strategic_ai ->
        updated_diplomatic = Map.put(strategic_ai.diplomatic_status, target_player_id, status)
        updated_strategic_ai = %{strategic_ai | diplomatic_status: updated_diplomatic}
        updated_strategic_ais = Map.put(state.strategic_ais, player_id, updated_strategic_ai)
        updated_state = %{state | strategic_ais: updated_strategic_ais}
        
        Logger.info("Diplomatic status changed: #{player_id} -> #{target_player_id}: #{status}")
        {:reply, :ok, updated_state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      active_unit_ais: map_size(state.unit_ais),
      active_strategic_ais: map_size(state.strategic_ais),
      known_resources: length(state.global_knowledge.resource_locations),
      known_enemies: map_size(state.global_knowledge.enemy_positions),
      strategic_locations: length(state.global_knowledge.strategic_locations),
      successful_strategies: length(state.learning_data.successful_strategies),
      failed_strategies: length(state.learning_data.failed_strategies),
      adaptation_rate: state.learning_data.adaptation_rate,
      personality_distribution: calculate_personality_distribution(state),
      goal_distribution: calculate_goal_distribution(state)
    }
    
    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:update_unit_experience, entity_id, experience_data}, state) do
    case Map.get(state.unit_ais, entity_id) do
      nil ->
        {:noreply, state}
        
      unit_ai ->
        updated_experience = merge_experience(unit_ai.experience, experience_data)
        updated_unit_ai = %{unit_ai | experience: updated_experience}
        updated_unit_ais = Map.put(state.unit_ais, entity_id, updated_unit_ai)
        updated_state = %{state | unit_ais: updated_unit_ais}
        
        Logger.debug("Updated experience for #{entity_id}: #{inspect(experience_data)}")
        {:noreply, updated_state}
    end
  end

  @impl true
  def handle_info(:ai_update, state) do
    Logger.debug("Processing AI updates")
    
    # Update unit AI behaviors
    updated_state = process_unit_ai_updates(state)
    
    # Update strategic AI planning
    processed_state = process_strategic_ai_updates(updated_state)
    
    # Update global knowledge
    final_state = update_global_knowledge(processed_state)
    
    # Schedule next update
    schedule_ai_updates()
    
    {:noreply, final_state}
  end

  @impl true
  def handle_info(:learning_update, state) do
    Logger.debug("Processing AI learning updates")
    
    # Analyze recent strategies and outcomes
    updated_state = analyze_strategy_outcomes(state)
    
    # Adapt AI behavior based on learning
    final_state = adapt_ai_behavior(updated_state)
    
    # Schedule next learning update
    schedule_learning_updates()
    
    {:noreply, final_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("DecisionEngine received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("DecisionEngine terminating: #{inspect(reason)}")
    Logger.info("Final AI stats:")
    Logger.info("  Unit AIs: #{map_size(state.unit_ais)}")
    Logger.info("  Strategic AIs: #{map_size(state.strategic_ais)}")
    Logger.info("  Learning data: #{length(state.learning_data.successful_strategies)} successes, #{length(state.learning_data.failed_strategies)} failures")
    :ok
  end

  # Private Helper Functions

  defp create_unit_ai(entity_id, ai_config) do
    personality = Map.get(ai_config, :personality_traits, select_random_personality())
    
    %{
      entity_id: entity_id,
      current_state: :idle,
      behavior_tree: create_behavior_tree(personality),
      target: nil,
      last_decision: :os.system_time(:millisecond),
      experience: %{
        kills: 0,
        deaths: 0,
        damage_dealt: 0,
        damage_received: 0
      },
      personality_traits: personality
    }
  end

  defp create_strategic_ai(player_id, strategy_config) do
    primary_goal = Map.get(strategy_config, :primary_goal, select_random_goal())
    
    %{
      player_id: player_id,
      primary_goal: primary_goal,
      secondary_goals: Map.get(strategy_config, :secondary_goals, select_secondary_goals(primary_goal)),
      resource_priorities: calculate_resource_priorities(primary_goal),
      threat_assessment: %{},
      diplomatic_status: %{},
      last_strategy_update: :os.system_time(:millisecond)
    }
  end

  defp select_random_personality do
    trait_count = :rand.uniform(3) + 1
    @personality_traits
    |> Enum.shuffle()
    |> Enum.take(trait_count)
  end

  defp select_random_goal do
    Enum.random(@strategic_goals)
  end

  defp select_secondary_goals(primary_goal) do
    @strategic_goals
    |> Enum.reject(&(&1 == primary_goal))
    |> Enum.shuffle()
    |> Enum.take(2)
  end

  defp calculate_resource_priorities(primary_goal) do
    case primary_goal do
      :economic_growth ->
        %{minerals: 0.8, gas: 0.6, energy: 0.9, food: 0.7, research_points: 0.5, rare_metals: 0.4}
      :military_buildup ->
        %{minerals: 0.9, gas: 0.7, energy: 0.6, food: 0.5, research_points: 0.3, rare_metals: 0.8}
      :research ->
        %{minerals: 0.5, gas: 0.6, energy: 0.8, food: 0.4, research_points: 1.0, rare_metals: 0.7}
      :expand ->
        %{minerals: 0.7, gas: 0.8, energy: 0.7, food: 0.9, research_points: 0.4, rare_metals: 0.5}
      :defend ->
        %{minerals: 0.8, gas: 0.5, energy: 0.7, food: 0.6, research_points: 0.6, rare_metals: 0.6}
      :diplomacy ->
        %{minerals: 0.6, gas: 0.5, energy: 0.5, food: 0.6, research_points: 0.7, rare_metals: 0.9}
    end
  end

  defp create_behavior_tree(personality_traits) do
    # Create a behavior tree based on personality
    if :aggressive in personality_traits do
      create_aggressive_behavior_tree()
    else if :defensive in personality_traits do
      create_defensive_behavior_tree()
    else if :economic in personality_traits do
      create_economic_behavior_tree()
    else
      create_balanced_behavior_tree()
    end
  end

  defp create_aggressive_behavior_tree do
    %{
      type: :selector,
      children: [
        %{type: :sequence, children: [
          %{type: :condition, condition: &has_enemy_target/2},
          %{type: :action, action: &attack_target/2}
        ]},
        %{type: :sequence, children: [
          %{type: :condition, condition: &can_find_enemy/2},
          %{type: :action, action: &move_to_enemy/2}
        ]},
        %{type: :action, action: &patrol_aggressively/2}
      ],
      status: :ready
    }
  end

  defp create_defensive_behavior_tree do
    %{
      type: :selector,
      children: [
        %{type: :sequence, children: [
          %{type: :condition, condition: &under_attack/2},
          %{type: :action, action: &defend_position/2}
        ]},
        %{type: :sequence, children: [
          %{type: :condition, condition: &has_enemy_in_range/2},
          %{type: :action, action: &attack_target/2}
        ]},
        %{type: :action, action: &patrol_defensively/2}
      ],
      status: :ready
    }
  end

  defp create_economic_behavior_tree do
    %{
      type: :selector,
      children: [
        %{type: :sequence, children: [
          %{type: :condition, condition: &can_gather_resources/2},
          %{type: :action, action: &gather_resources/2}
        ]},
        %{type: :sequence, children: [
          %{type: :condition, condition: &can_trade/2},
          %{type: :action, action: &execute_trade/2}
        ]},
        %{type: :action, action: &scout_for_resources/2}
      ],
      status: :ready
    }
  end

  defp create_balanced_behavior_tree do
    %{
      type: :selector,
      children: [
        %{type: :sequence, children: [
          %{type: :condition, condition: &under_attack/2},
          %{type: :action, action: &defend_or_retreat/2}
        ]},
        %{type: :sequence, children: [
          %{type: :condition, condition: &has_advantageous_target/2},
          %{type: :action, action: &attack_target/2}
        ]},
        %{type: :action, action: &patrol_balanced/2}
      ],
      status: :ready
    }
  end

  defp execute_unit_behavior_tree(unit_ai, _global_state) do
    # Execute behavior tree and return decision
    # This is a simplified version - real implementation would traverse the tree
    
    case unit_ai.current_state do
      :idle ->
        if :aggressive in unit_ai.personality_traits do
          %{action: :seek_combat, target: find_nearest_enemy(unit_ai.entity_id)}
        else if :economic in unit_ai.personality_traits do
          %{action: :gather_resources, target: find_nearest_resource()}
        else
          %{action: :patrol, waypoints: generate_patrol_waypoints()}
        end
        
      :moving ->
        %{action: :continue_movement, target: unit_ai.target}
        
      :attacking ->
        if unit_ai.target do
          %{action: :continue_attack, target: unit_ai.target}
        else
          %{action: :seek_target, area: get_current_position(unit_ai.entity_id)}
        end
        
      :retreating ->
        %{action: :retreat_to_safety, destination: find_safe_position(unit_ai.entity_id)}
        
      _ ->
        %{action: :idle, duration: 1000}
    end
  end

  defp execute_strategic_planning(strategic_ai, global_state) do
    # Execute strategic planning based on AI's goals and current situation
    
    case strategic_ai.primary_goal do
      :economic_growth ->
        plan_economic_expansion(strategic_ai, global_state)
        
      :military_buildup ->
        plan_military_expansion(strategic_ai, global_state)
        
      :research ->
        plan_research_priorities(strategic_ai, global_state)
        
      :expand ->
        plan_territorial_expansion(strategic_ai, global_state)
        
      :defend ->
        plan_defensive_strategy(strategic_ai, global_state)
        
      :diplomacy ->
        plan_diplomatic_actions(strategic_ai, global_state)
    end
  end

  defp plan_economic_expansion(strategic_ai, _global_state) do
    %{
      strategy: :economic_growth,
      actions: [
        %{type: :build_economic_structures, priority: 0.9},
        %{type: :establish_trade_routes, priority: 0.8},
        %{type: :optimize_resource_allocation, priority: 0.7}
      ],
      resource_allocation: strategic_ai.resource_priorities,
      timeline: :immediate
    }
  end

  defp plan_military_expansion(strategic_ai, _global_state) do
    %{
      strategy: :military_buildup,
      actions: [
        %{type: :build_military_units, priority: 0.9},
        %{type: :construct_defensive_positions, priority: 0.7},
        %{type: :research_military_tech, priority: 0.6}
      ],
      resource_allocation: strategic_ai.resource_priorities,
      timeline: :immediate
    }
  end

  defp plan_research_priorities(strategic_ai, _global_state) do
    %{
      strategy: :research_focus,
      actions: [
        %{type: :allocate_research_points, priority: 1.0},
        %{type: :build_research_facilities, priority: 0.8},
        %{type: :gather_rare_materials, priority: 0.7}
      ],
      resource_allocation: strategic_ai.resource_priorities,
      timeline: :long_term
    }
  end

  defp plan_territorial_expansion(strategic_ai, global_state) do
    expansion_targets = identify_expansion_targets(global_state)
    
    %{
      strategy: :territorial_expansion,
      actions: [
        %{type: :scout_expansion_sites, priority: 0.9, targets: expansion_targets},
        %{type: :prepare_colony_ships, priority: 0.8},
        %{type: :secure_expansion_routes, priority: 0.7}
      ],
      resource_allocation: strategic_ai.resource_priorities,
      timeline: :medium_term
    }
  end

  defp plan_defensive_strategy(strategic_ai, global_state) do
    threats = assess_threats(strategic_ai, global_state)
    
    %{
      strategy: :defensive_posture,
      actions: [
        %{type: :reinforce_defenses, priority: 0.9, threats: threats},
        %{type: :position_defensive_units, priority: 0.8},
        %{type: :establish_early_warning, priority: 0.7}
      ],
      resource_allocation: strategic_ai.resource_priorities,
      timeline: :immediate
    }
  end

  defp plan_diplomatic_actions(strategic_ai, global_state) do
    diplomatic_opportunities = identify_diplomatic_opportunities(strategic_ai, global_state)
    
    %{
      strategy: :diplomatic_engagement,
      actions: [
        %{type: :initiate_negotiations, priority: 0.8, opportunities: diplomatic_opportunities},
        %{type: :offer_trade_agreements, priority: 0.7},
        %{type: :form_strategic_alliances, priority: 0.9}
      ],
      resource_allocation: strategic_ai.resource_priorities,
      timeline: :ongoing
    }
  end

  # Behavior Tree Condition Functions

  defp has_enemy_target(unit_ai, _global_state) do
    unit_ai.target != nil
  end

  defp can_find_enemy(unit_ai, global_state) do
    enemies = Map.get(global_state.global_knowledge, :enemy_positions, %{})
    not Enum.empty?(enemies)
  end

  defp under_attack(unit_ai, _global_state) do
    # Mock condition - would check if unit is taking damage
    unit_ai.experience.damage_received > 0
  end

  defp has_enemy_in_range(_unit_ai, _global_state) do
    # Mock condition - would check for enemies within weapon range
    :rand.uniform() < 0.3
  end

  defp can_gather_resources(_unit_ai, global_state) do
    not Enum.empty?(global_state.global_knowledge.resource_locations)
  end

  defp can_trade(_unit_ai, _global_state) do
    # Mock condition - would check market conditions
    :rand.uniform() < 0.2
  end

  defp has_advantageous_target(unit_ai, _global_state) do
    # Mock condition - would analyze target strength vs unit strength
    unit_ai.experience.kills > unit_ai.experience.deaths
  end

  # Behavior Tree Action Functions

  defp attack_target(unit_ai, _global_state) do
    Logger.debug("Unit #{unit_ai.entity_id} attacking target #{unit_ai.target}")
    %{action: :attack, target: unit_ai.target}
  end

  defp move_to_enemy(unit_ai, _global_state) do
    Logger.debug("Unit #{unit_ai.entity_id} moving to engage enemy")
    %{action: :move, destination: find_nearest_enemy(unit_ai.entity_id)}
  end

  defp defend_position(unit_ai, _global_state) do
    Logger.debug("Unit #{unit_ai.entity_id} defending position")
    %{action: :defend, position: get_current_position(unit_ai.entity_id)}
  end

  defp patrol_aggressively(unit_ai, _global_state) do
    %{action: :patrol, waypoints: generate_aggressive_patrol(unit_ai.entity_id)}
  end

  defp patrol_defensively(unit_ai, _global_state) do
    %{action: :patrol, waypoints: generate_defensive_patrol(unit_ai.entity_id)}
  end

  defp patrol_balanced(unit_ai, _global_state) do
    %{action: :patrol, waypoints: generate_balanced_patrol(unit_ai.entity_id)}
  end

  defp gather_resources(unit_ai, global_state) do
    resource_location = find_nearest_resource_location(unit_ai.entity_id, global_state)
    %{action: :gather, target: resource_location}
  end

  defp execute_trade(_unit_ai, _global_state) do
    %{action: :trade, resource: :minerals, quantity: 100}
  end

  defp scout_for_resources(unit_ai, _global_state) do
    %{action: :scout, area: generate_scouting_area(unit_ai.entity_id)}
  end

  defp defend_or_retreat(unit_ai, _global_state) do
    if unit_ai.experience.damage_received > 50 do
      %{action: :retreat, destination: find_safe_position(unit_ai.entity_id)}
    else
      %{action: :defend, position: get_current_position(unit_ai.entity_id)}
    end
  end

  # Helper Functions

  defp generate_resource_locations do
    # Generate random resource locations across the map
    for _i <- 1..20 do
      {
        :rand.uniform(10000) * 1.0,
        :rand.uniform(10000) * 1.0
      }
    end
  end

  defp generate_strategic_locations do
    # Generate key strategic positions
    [
      {2500.0, 2500.0}, # Northwest strategic point
      {7500.0, 2500.0}, # Northeast strategic point
      {2500.0, 7500.0}, # Southwest strategic point
      {7500.0, 7500.0}, # Southeast strategic point
      {5000.0, 5000.0}  # Center strategic point
    ]
  end

  defp find_nearest_enemy(entity_id) do
    # Mock function - would query world state for enemies
    "enemy_" <> Integer.to_string(:rand.uniform(100))
  end

  defp find_nearest_resource do
    # Mock function - would find actual resource locations
    {float(:rand.uniform(10000)), float(:rand.uniform(10000))}
  end

  defp find_nearest_resource_location(entity_id, global_state) do
    entity_pos = get_current_position(entity_id)
    
    global_state.global_knowledge.resource_locations
    |> Enum.min_by(fn resource_pos ->
      calculate_distance(entity_pos, resource_pos)
    end)
  end

  defp get_current_position(entity_id) do
    # Mock position - would query entity system
    {float(:rand.uniform(10000)), float(:rand.uniform(10000))}
  end

  defp find_safe_position(entity_id) do
    # Mock function - would analyze threat map and find safe retreat position
    current_pos = get_current_position(entity_id)
    {elem(current_pos, 0) - 500.0, elem(current_pos, 1) - 500.0}
  end

  defp generate_patrol_waypoints do
    # Generate random patrol waypoints
    for _i <- 1..4 do
      {float(:rand.uniform(1000)), float(:rand.uniform(1000))}
    end
  end

  defp generate_aggressive_patrol(entity_id) do
    current_pos = get_current_position(entity_id)
    # Generate patrol points towards enemy territory
    [
      {elem(current_pos, 0) + 200.0, elem(current_pos, 1)},
      {elem(current_pos, 0) + 400.0, elem(current_pos, 1) + 200.0},
      {elem(current_pos, 0) + 200.0, elem(current_pos, 1) + 400.0},
      current_pos
    ]
  end

  defp generate_defensive_patrol(entity_id) do
    current_pos = get_current_position(entity_id)
    # Generate patrol points around current position
    [
      {elem(current_pos, 0) + 100.0, elem(current_pos, 1)},
      {elem(current_pos, 0), elem(current_pos, 1) + 100.0},
      {elem(current_pos, 0) - 100.0, elem(current_pos, 1)},
      {elem(current_pos, 0), elem(current_pos, 1) - 100.0}
    ]
  end

  defp generate_balanced_patrol(entity_id) do
    current_pos = get_current_position(entity_id)
    # Generate moderate patrol area
    [
      {elem(current_pos, 0) + 150.0, elem(current_pos, 1) + 150.0},
      {elem(current_pos, 0) - 150.0, elem(current_pos, 1) + 150.0},
      {elem(current_pos, 0) - 150.0, elem(current_pos, 1) - 150.0},
      {elem(current_pos, 0) + 150.0, elem(current_pos, 1) - 150.0}
    ]
  end

  defp generate_scouting_area(entity_id) do
    current_pos = get_current_position(entity_id)
    {elem(current_pos, 0) + 1000.0, elem(current_pos, 1) + 1000.0}
  end

  defp calculate_distance({x1, y1}, {x2, y2}) do
    :math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1))
  end

  defp merge_experience(current_exp, new_data) do
    %{
      kills: current_exp.kills + Map.get(new_data, :kills, 0),
      deaths: current_exp.deaths + Map.get(new_data, :deaths, 0),
      damage_dealt: current_exp.damage_dealt + Map.get(new_data, :damage_dealt, 0),
      damage_received: current_exp.damage_received + Map.get(new_data, :damage_received, 0)
    }
  end

  defp identify_expansion_targets(global_state) do
    # Identify good locations for expansion
    global_state.global_knowledge.strategic_locations
    |> Enum.filter(fn _location -> :rand.uniform() < 0.6 end)
    |> Enum.take(3)
  end

  defp assess_threats(strategic_ai, global_state) do
    # Analyze threats to the player
    global_state.global_knowledge.enemy_positions
    |> Enum.map(fn {enemy_id, position} ->
      %{enemy_id: enemy_id, position: position, threat_level: :rand.uniform()}
    end)
    |> Enum.filter(&(&1.threat_level > 0.5))
  end

  defp identify_diplomatic_opportunities(strategic_ai, _global_state) do
    # Find potential diplomatic partners
    strategic_ai.diplomatic_status
    |> Enum.filter(fn {_player_id, status} -> status == :neutral end)
    |> Enum.map(fn {player_id, _status} -> 
      %{player_id: player_id, opportunity_type: Enum.random([:trade, :alliance, :non_aggression])}
    end)
  end

  defp calculate_personality_distribution(state) do
    state.unit_ais
    |> Enum.flat_map(fn {_id, unit_ai} -> unit_ai.personality_traits end)
    |> Enum.reduce(%{}, fn trait, acc -> Map.update(acc, trait, 1, &(&1 + 1)) end)
  end

  defp calculate_goal_distribution(state) do
    state.strategic_ais
    |> Enum.map(fn {_id, strategic_ai} -> strategic_ai.primary_goal end)
    |> Enum.reduce(%{}, fn goal, acc -> Map.update(acc, goal, 1, &(&1 + 1)) end)
  end

  defp process_unit_ai_updates(state) do
    # Process behavior updates for all unit AIs
    state
  end

  defp process_strategic_ai_updates(state) do
    # Process strategic planning updates for all player AIs
    state
  end

  defp update_global_knowledge(state) do
    # Update global knowledge base with new information
    state
  end

  defp analyze_strategy_outcomes(state) do
    # Analyze the success/failure of recent strategies
    state
  end

  defp adapt_ai_behavior(state) do
    # Adapt AI behavior based on learning outcomes
    updated_adaptation_rate = min(0.5, state.learning_data.adaptation_rate * 1.01)
    updated_learning = %{state.learning_data | adaptation_rate: updated_adaptation_rate}
    
    %{state | learning_data: updated_learning}
  end

  defp schedule_ai_updates do
    Process.send_after(self(), :ai_update, 2_000) # Every 2 seconds
  end

  defp schedule_learning_updates do
    Process.send_after(self(), :learning_update, 30_000) # Every 30 seconds
  end
end
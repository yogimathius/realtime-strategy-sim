defmodule RealtimeStrategySim.Entity.UnitActorTest do
  use ExUnit.Case, async: true
  alias RealtimeStrategySim.Entity.UnitActor

  describe "UnitActor lifecycle" do
    test "can spawn a unit actor with initial state" do
      unit_params = %{
        id: "unit_001",
        type: :soldier,
        position: {100.0, 200.0},
        health: 100,
        energy: 100
      }

      {:ok, pid} = UnitActor.start_link(unit_params)
      
      # Actor should be alive
      assert Process.alive?(pid)
      
      # Should have correct initial state
      state = UnitActor.get_state(pid)
      assert state.id == "unit_001"
      assert state.type == :soldier
      assert state.position == {100.0, 200.0}
      assert state.health == 100
      assert state.energy == 100
    end

    test "can move unit to new position" do
      unit_params = %{
        id: "unit_002", 
        type: :soldier,
        position: {0.0, 0.0},
        health: 100,
        energy: 100
      }

      {:ok, pid} = UnitActor.start_link(unit_params)
      
      # Move unit
      :ok = UnitActor.move_to(pid, {50.0, 75.0})
      
      # Verify new position
      state = UnitActor.get_state(pid)
      assert state.position == {50.0, 75.0}
    end

    test "unit takes damage and updates health" do
      unit_params = %{
        id: "unit_003",
        type: :soldier, 
        position: {0.0, 0.0},
        health: 100,
        energy: 100
      }

      {:ok, pid} = UnitActor.start_link(unit_params)
      
      # Take damage
      :ok = UnitActor.take_damage(pid, 30)
      
      # Verify health reduced
      state = UnitActor.get_state(pid)
      assert state.health == 70
    end

    test "unit dies when health reaches zero" do
      unit_params = %{
        id: "unit_004",
        type: :soldier,
        position: {0.0, 0.0}, 
        health: 50,
        energy: 100
      }

      {:ok, pid} = UnitActor.start_link(unit_params)
      
      # Take fatal damage
      :ok = UnitActor.take_damage(pid, 60)
      
      # Unit should die (process should terminate)
      :timer.sleep(100) # Allow time for process termination
      refute Process.alive?(pid)
    end

    test "can consume energy for actions" do
      unit_params = %{
        id: "unit_005",
        type: :soldier,
        position: {0.0, 0.0},
        health: 100, 
        energy: 100
      }

      {:ok, pid} = UnitActor.start_link(unit_params)
      
      # Consume energy
      :ok = UnitActor.consume_energy(pid, 25)
      
      # Verify energy reduced
      state = UnitActor.get_state(pid)
      assert state.energy == 75
    end
  end

  describe "UnitActor message handling" do
    test "can receive and process attack command" do
      attacker_params = %{
        id: "attacker",
        type: :soldier,
        position: {0.0, 0.0},
        health: 100,
        energy: 100
      }

      target_params = %{
        id: "target", 
        type: :soldier,
        position: {10.0, 10.0},
        health: 100,
        energy: 100
      }

      {:ok, attacker_pid} = UnitActor.start_link(attacker_params)
      {:ok, target_pid} = UnitActor.start_link(target_params)
      
      # Attack command
      :ok = UnitActor.attack_target(attacker_pid, target_pid)
      
      # Give time for message processing
      :timer.sleep(50)
      
      # Verify attacker consumed energy
      attacker_state = UnitActor.get_state(attacker_pid)
      assert attacker_state.energy < 100
      
      # Verify target took damage
      target_state = UnitActor.get_state(target_pid)
      assert target_state.health < 100
    end
  end
end
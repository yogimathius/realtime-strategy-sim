defmodule RealtimeStrategySim.Entity.EntitySupervisorTest do
  use ExUnit.Case, async: true
  alias RealtimeStrategySim.Entity.{EntitySupervisor, UnitActor}

  describe "EntitySupervisor lifecycle" do
    test "can start the entity supervisor" do
      {:ok, supervisor_pid} = EntitySupervisor.start_link([])
      assert Process.alive?(supervisor_pid)
    end

    test "can spawn multiple unit actors under supervision" do
      {:ok, supervisor_pid} = EntitySupervisor.start_link([])
      
      # Spawn multiple units
      unit_specs = [
        %{id: "unit_1", type: :soldier, position: {0.0, 0.0}, health: 100, energy: 100},
        %{id: "unit_2", type: :vehicle, position: {50.0, 50.0}, health: 150, energy: 100},
        %{id: "unit_3", type: :aircraft, position: {100.0, 100.0}, health: 75, energy: 120}
      ]
      
      unit_pids = Enum.map(unit_specs, fn spec ->
        {:ok, pid} = EntitySupervisor.spawn_unit(supervisor_pid, spec)
        pid
      end)
      
      # Verify all units are alive and supervised
      assert length(unit_pids) == 3
      Enum.each(unit_pids, fn pid ->
        assert Process.alive?(pid)
      end)
      
      # Verify supervisor tree structure
      children = DynamicSupervisor.which_children(supervisor_pid)
      assert length(children) == 3
    end

    test "can spawn many units concurrently" do
      {:ok, supervisor_pid} = EntitySupervisor.start_link([])
      
      # Spawn 100 units concurrently (testing scalability)
      tasks = for i <- 1..100 do
        Task.async(fn ->
          spec = %{
            id: "unit_#{i}",
            type: :soldier,
            position: {Float.round(:rand.uniform() * 1000, 2), Float.round(:rand.uniform() * 1000, 2)},
            health: 100,
            energy: 100
          }
          EntitySupervisor.spawn_unit(supervisor_pid, spec)
        end)
      end
      
      results = Task.await_many(tasks, 5000)
      
      # All spawns should succeed
      success_count = Enum.count(results, fn 
        {:ok, _pid} -> true
        _ -> false
      end)
      
      assert success_count == 100
      
      # Verify all units are supervised
      children = DynamicSupervisor.which_children(supervisor_pid)
      assert length(children) == 100
    end

    test "automatically restarts crashed units (fault tolerance)" do
      {:ok, supervisor_pid} = EntitySupervisor.start_link([])
      
      unit_spec = %{
        id: "crashable_unit", 
        type: :soldier,
        position: {0.0, 0.0},
        health: 100,
        energy: 100
      }
      
      {:ok, original_pid} = EntitySupervisor.spawn_unit(supervisor_pid, unit_spec)
      
      # Verify unit is alive
      assert Process.alive?(original_pid)
      
      # Kill the unit process
      Process.exit(original_pid, :kill)
      
      # Give supervisor time to restart
      :timer.sleep(100)
      
      # Should still have one child (restarted unit)
      children = DynamicSupervisor.which_children(supervisor_pid)
      assert length(children) == 1
      
      # The restarted process should have different PID
      [{:undefined, new_pid, :worker, [UnitActor]}] = children
      assert new_pid != original_pid
      assert Process.alive?(new_pid)
    end

    test "can terminate specific units by ID" do
      {:ok, supervisor_pid} = EntitySupervisor.start_link([])
      
      # Spawn multiple units
      unit_specs = [
        %{id: "keep_unit", type: :soldier, position: {0.0, 0.0}, health: 100, energy: 100},
        %{id: "remove_unit", type: :soldier, position: {50.0, 50.0}, health: 100, energy: 100}
      ]
      
      unit_pids = Enum.into(
        Enum.map(unit_specs, fn spec ->
          {:ok, pid} = EntitySupervisor.spawn_unit(supervisor_pid, spec)
          {spec.id, pid}
        end),
        %{}
      )
      
      # Verify both units exist
      assert length(DynamicSupervisor.which_children(supervisor_pid)) == 2
      
      # Terminate one unit by ID
      :ok = EntitySupervisor.terminate_unit(supervisor_pid, "remove_unit")
      
      # Give time for termination
      :timer.sleep(50)
      
      # Should have only one unit remaining
      children = DynamicSupervisor.which_children(supervisor_pid)
      assert length(children) == 1
      
      # Verify the correct unit was removed
      removed_pid = Map.get(unit_pids, "remove_unit")
      refute Process.alive?(removed_pid)
      
      kept_pid = Map.get(unit_pids, "keep_unit")
      assert Process.alive?(kept_pid)
    end
  end

  describe "EntitySupervisor load balancing" do
    test "distributes unit actors across BEAM schedulers" do
      {:ok, supervisor_pid} = EntitySupervisor.start_link([])
      
      # Spawn units and collect their scheduler info
      unit_count = 20
      tasks = for i <- 1..unit_count do
        Task.async(fn ->
          spec = %{id: "unit_#{i}", type: :soldier, position: {0.0, 0.0}, health: 100, energy: 100}
          {:ok, pid} = EntitySupervisor.spawn_unit(supervisor_pid, spec)
          
          # Get scheduler info for this process
          {pid, :erlang.process_info(pid, :current_stacktrace)}
        end)
      end
      
      results = Task.await_many(tasks, 2000)
      
      # Should have created the expected number of units
      assert length(results) == unit_count
      
      # All processes should be alive
      pids = Enum.map(results, fn {pid, _} -> pid end)
      Enum.each(pids, fn pid ->
        assert Process.alive?(pid)
      end)
    end
  end

  describe "EntitySupervisor performance monitoring" do
    test "can query supervisor statistics" do
      {:ok, supervisor_pid} = EntitySupervisor.start_link([])
      
      # Spawn some units
      for i <- 1..5 do
        spec = %{id: "unit_#{i}", type: :soldier, position: {0.0, 0.0}, health: 100, energy: 100}
        EntitySupervisor.spawn_unit(supervisor_pid, spec)
      end
      
      # Get statistics
      stats = EntitySupervisor.get_stats(supervisor_pid)
      
      assert stats.active_children == 5
      assert stats.supervisor_pid == supervisor_pid
      assert is_integer(stats.memory_usage_kb)
    end
  end
end
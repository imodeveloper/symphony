defmodule SymphonyElixir.OperationsTest do
  use SymphonyElixir.TestSupport

  defmodule FakeLinearClient do
    def graphql(query, variables) do
      send(Application.fetch_env!(:symphony_elixir, :operations_test_recipient), {:graphql, query, variables})

      cond do
        String.contains?(query, "SymphonyWatchdogProject") ->
          {:ok,
           %{
             "data" => %{
               "projects" => %{
                 "nodes" => [
                   %{"id" => "project-1", "teams" => %{"nodes" => [%{"id" => "team-1"}]}}
                 ]
               }
             }
           }}

        String.contains?(query, "SymphonyWatchdogTeam") ->
          {:ok,
           %{
             "data" => %{
               "team" => %{
                 "states" => %{"nodes" => [%{"id" => "state-todo", "name" => "Todo"}]},
                 "labels" => %{"nodes" => [%{"id" => "label-chore", "name" => "Chore"}]}
               }
             }
           }}

        String.contains?(query, "SymphonyWatchdogIssue") ->
          state_name = Application.get_env(:symphony_elixir, :operations_test_watchdog_state, "Done")

          {:ok,
           %{
             "data" => %{
               "issues" => %{
                 "nodes" => [
                   %{
                     "id" => "issue-watchdog",
                     "identifier" => "IMO-8",
                     "title" => "Monitor Watchdog",
                     "url" => "https://linear.example/IMO-8",
                     "state" => %{"name" => state_name}
                   }
                 ]
               }
             }
           }}

        String.contains?(query, "SymphonyPulseWatchdogIssue") ->
          state_name =
            if Map.has_key?(variables.input, :stateId) do
              "Todo"
            else
              Application.get_env(:symphony_elixir, :operations_test_watchdog_state, "Todo")
            end

          {:ok,
           %{
             "data" => %{
               "issueUpdate" => %{
                 "success" => true,
                 "issue" => %{
                   "id" => variables.issueId,
                   "identifier" => "IMO-8",
                   "title" => "Monitor Watchdog",
                   "url" => "https://linear.example/IMO-8",
                   "state" => %{"name" => state_name}
                 }
               }
             }
           }}
      end
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)
    operations_test_recipient = Application.get_env(:symphony_elixir, :operations_test_recipient)
    operations_test_watchdog_state = Application.get_env(:symphony_elixir, :operations_test_watchdog_state)

    on_exit(fn ->
      restore_application_env(:linear_client_module, linear_client_module)
      restore_application_env(:operations_test_recipient, operations_test_recipient)
      restore_application_env(:operations_test_watchdog_state, operations_test_watchdog_state)
    end)

    :ok
  end

  test "parses df output into byte counts" do
    output = """
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/disk1 1000 400 600 40% /
    """

    assert {:ok, usage} = SymphonyElixir.Operations.parse_df_output(output, "/")
    assert usage.total_bytes == 1_024_000
    assert usage.available_bytes == 614_400
    assert usage.used_percent == 40
  end

  test "pauses dispatch when disk free space is below threshold" do
    write_workflow_file!(Workflow.workflow_file_path(),
      operations_disk_path: "/tmp",
      operations_disk_pause_threshold_bytes: 1_000,
      operations_cleanup_command: nil
    )

    {:ok, pid} =
      SymphonyElixir.Operations.start_link(
        name: :"operations-test-#{System.unique_integer([:positive])}",
        auto_schedule?: false,
        disk_usage_fun: fn path ->
          {:ok, %{path: path, total_bytes: 10_000, available_bytes: 900, used_percent: 91}}
        end
      )

    send(pid, :check_disk)

    assert %{paused?: true, reason: reason} = wait_for_dispatch_pause(pid)
    assert reason =~ "below threshold"
  end

  test "stale worktree cleanup deletes old inactive directories and skips active issues" do
    root = Path.join(System.tmp_dir!(), "symphony-stale-worktrees-#{System.unique_integer([:positive])}")
    old_identifier = "IMO-OLD"
    active_identifier = "IMO-ACTIVE"
    old_path = Path.join(root, old_identifier)
    active_path = Path.join(root, active_identifier)

    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(old_path)
    File.mkdir_p!(active_path)

    System.cmd("touch", ["-t", "202001010000", old_path])
    System.cmd("touch", ["-t", "202001010000", active_path])

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "issue-active", identifier: active_identifier, state: "Todo", title: "Active"}
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      operations_stale_worktree_delete: true,
      operations_stale_worktree_ttl_hours: 1
    )

    {:ok, pid} =
      SymphonyElixir.Operations.start_link(
        name: :"operations-stale-test-#{System.unique_integer([:positive])}",
        auto_schedule?: false
      )

    send(pid, :check_stale_worktrees)

    stale = wait_for_stale_check(pid)
    assert stale.status == "checked"
    assert old_identifier in stale.deleted
    assert active_identifier in stale.skipped_active
    refute File.exists?(old_path)
    assert File.dir?(active_path)
  end

  test "watchdog issue pulse refreshes quick-run metadata on inactive issue" do
    description = "Quick watchdog description"
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :operations_test_recipient, self())
    Application.put_env(:symphony_elixir, :operations_test_watchdog_state, "Done")

    write_workflow_file!(Workflow.workflow_file_path(),
      operations_watchdog_issue_enabled: true,
      operations_watchdog_issue_title: "Monitor Watchdog",
      operations_watchdog_issue_description: description,
      operations_watchdog_issue_state: "Todo",
      operations_watchdog_issue_assignee_id: "user-1",
      operations_watchdog_issue_priority: 3,
      operations_watchdog_issue_labels: ["Chore"]
    )

    {:ok, pid} =
      SymphonyElixir.Operations.start_link(
        name: :"operations-watchdog-test-#{System.unique_integer([:positive])}",
        auto_schedule?: false
      )

    send(pid, :ensure_watchdog_issue)

    watchdog = wait_for_watchdog_check(pid)
    assert watchdog.status == "ready"
    assert watchdog.action == "pulsed"

    assert_receive {:graphql, update_query,
                    %{
                      issueId: "issue-watchdog",
                      input: %{
                        assigneeId: "user-1",
                        description: ^description,
                        priority: 3,
                        stateId: "state-todo"
                      }
                    }}

    assert update_query =~ "IssueUpdateInput"
  end

  test "active watchdog issue keeps state and still refreshes quick-run metadata" do
    description = "Quick active watchdog description"
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :operations_test_recipient, self())
    Application.put_env(:symphony_elixir, :operations_test_watchdog_state, "Todo")

    write_workflow_file!(Workflow.workflow_file_path(),
      operations_watchdog_issue_enabled: true,
      operations_watchdog_issue_title: "Monitor Watchdog",
      operations_watchdog_issue_description: description,
      operations_watchdog_issue_state: "Todo",
      operations_watchdog_issue_assignee_id: "user-1",
      operations_watchdog_issue_priority: 3,
      operations_watchdog_issue_labels: ["Chore"]
    )

    {:ok, pid} =
      SymphonyElixir.Operations.start_link(
        name: :"operations-active-watchdog-test-#{System.unique_integer([:positive])}",
        auto_schedule?: false
      )

    send(pid, :ensure_watchdog_issue)

    watchdog = wait_for_watchdog_check(pid)
    assert watchdog.status == "ready"
    assert watchdog.action == "already_active"

    assert_receive {:graphql, _update_query,
                    %{
                      issueId: "issue-watchdog",
                      input: %{
                        assigneeId: "user-1",
                        description: ^description,
                        priority: 3
                      }
                    }}

    refute_receive {:graphql, _update_query, %{input: %{stateId: _state_id}}}
  end

  defp wait_for_dispatch_pause(pid, deadline_ms \\ System.monotonic_time(:millisecond) + 500) do
    pause = SymphonyElixir.Operations.dispatch_pause(pid)

    if pause.paused? do
      pause
    else
      if System.monotonic_time(:millisecond) > deadline_ms do
        flunk("operations dispatch did not pause")
      else
        Process.sleep(10)
        wait_for_dispatch_pause(pid, deadline_ms)
      end
    end
  end

  defp wait_for_stale_check(pid, deadline_ms \\ System.monotonic_time(:millisecond) + 500) do
    stale = SymphonyElixir.Operations.snapshot(pid).stale_worktrees

    if stale.status == "checked" do
      stale
    else
      if System.monotonic_time(:millisecond) > deadline_ms do
        flunk("stale worktree cleanup did not complete")
      else
        Process.sleep(10)
        wait_for_stale_check(pid, deadline_ms)
      end
    end
  end

  defp wait_for_watchdog_check(pid, deadline_ms \\ System.monotonic_time(:millisecond) + 500) do
    watchdog = SymphonyElixir.Operations.snapshot(pid).linear_watchdog

    if watchdog.status != "unknown" do
      watchdog
    else
      if System.monotonic_time(:millisecond) > deadline_ms do
        flunk("watchdog issue check did not complete")
      else
        Process.sleep(10)
        wait_for_watchdog_check(pid, deadline_ms)
      end
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

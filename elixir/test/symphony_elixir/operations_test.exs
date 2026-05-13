defmodule SymphonyElixir.OperationsTest do
  use SymphonyElixir.TestSupport

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
end

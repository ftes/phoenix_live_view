defmodule Phoenix.LiveView.Async do
  @moduledoc false

  alias Phoenix.LiveView.{AsyncResult, Socket, Channel}

  def start_async(%Socket{} = socket, name, func)
      when is_atom(name) and is_function(func, 0) do
    run_async_task(socket, name, func, :start)
  end

  def assign_async(%Socket{} = socket, key_or_keys, func)
      when (is_atom(key_or_keys) or is_list(key_or_keys)) and
             is_function(func, 0) do
    keys = List.wrap(key_or_keys)

    # verifies result inside task
    wrapped_func = fn ->
      case func.() do
        {:ok, %{} = assigns} ->
          if Enum.find(keys, &(not is_map_key(assigns, &1))) do
            raise ArgumentError, """
            expected assign_async to return map of assigns for all keys
            in #{inspect(keys)}, but got: #{inspect(assigns)}
            """
          else
            {:ok, assigns}
          end

        {:error, reason} ->
          {:error, reason}

        other ->
          raise ArgumentError, """
          expected assign_async to return {:ok, map} of
          assigns for #{inspect(keys)} or {:error, reason}, got: #{inspect(other)}
          """
      end
    end

    new_assigns =
      Enum.map(keys, fn key ->
        case socket.assigns do
          %{^key => %AsyncResult{ok?: true} = existing} -> {key, AsyncResult.loading(existing, keys)}
          %{} -> {key, AsyncResult.loading(keys)}
        end
      end)

    socket
    |> Phoenix.Component.assign(new_assigns)
    |> run_async_task(keys, wrapped_func, :assign)
  end

  defp run_async_task(%Socket{} = socket, keys, func, kind) do
    if Phoenix.LiveView.connected?(socket) do
      socket = cancel_existing(socket, keys)
      lv_pid = self()
      cid = cid(socket)
      {:ok, pid} = Task.start_link(fn -> do_async(lv_pid, cid, keys, func, kind) end)

      ref =
        :erlang.monitor(:process, pid, alias: :reply_demonitor, tag: {__MODULE__, keys, cid, kind})

      send(pid, {:context, ref})

      update_private_async(socket, &Map.put(&1, keys, {ref, pid, kind}))
    else
      socket
    end
  end

  defp do_async(lv_pid, cid, keys, func, async_kind) do
    receive do
      {:context, ref} ->
        try do
          result = func.()
          Channel.report_async_result(ref, async_kind, ref, cid, keys, {:ok, result})
        catch
          catch_kind, reason ->
            Process.unlink(lv_pid)
            caught_result = to_exit(catch_kind, reason, __STACKTRACE__)
            Channel.report_async_result(ref, async_kind, ref, cid, keys, caught_result)
            :erlang.raise(catch_kind, reason, __STACKTRACE__)
        end
    end
  end

  def cancel_async(%Socket{} = socket, %AsyncResult{} = result, reason) do
    case result do
      %AsyncResult{loading: keys} when not is_nil(keys) ->
        new_assigns = for key <- keys, do: {key, AsyncResult.failed(result, {:exit, reason})}

        socket
        |> Phoenix.Component.assign(new_assigns)
        |> cancel_async(keys, reason)

      %AsyncResult{} ->
        socket
    end
  end

  def cancel_async(%Socket{} = socket, keys, _reason) do
    case get_private_async(socket, keys) do
      {_ref, pid, _kind} when is_pid(pid) ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        update_private_async(socket, &Map.delete(&1, keys))

      nil ->
        raise ArgumentError, "unknown async assign #{inspect(keys)}"
    end
  end

  def handle_async(socket, maybe_component, kind, keys, ref, result) do
    case prune_current_async(socket, keys, ref) do
      {:ok, pruned_socket} ->
        handle_kind(pruned_socket, maybe_component, kind, keys, result)

      :error ->
        socket
    end
  end

  def handle_trap_exit(socket, maybe_component, kind, keys, ref, reason) do
    handle_async(socket, maybe_component, kind, keys, ref, {:exit, reason})
  end

  defp handle_kind(socket, maybe_component, :start, keys, result) do
    callback_mod = maybe_component || socket.view

    case callback_mod.handle_async(keys, result, socket) do
      {:noreply, %Socket{} = new_socket} ->
        new_socket

      other ->
        raise ArgumentError, """
        expected #{inspect(callback_mod)}.handle_async/3 to return {:noreply, socket}, got:

            #{inspect(other)}
        """
    end
  end

  defp handle_kind(socket, _maybe_component, :assign, keys, result) do
    case result do
      {:ok, {:ok, %{} = assigns}} ->
        new_assigns =
          for {key, val} <- assigns do
            {key, AsyncResult.ok(get_current_async!(socket, key), val)}
          end

        Phoenix.Component.assign(socket, new_assigns)

      {:ok, {:error, reason}} ->
        new_assigns =
          for key <- keys do
            {key, AsyncResult.failed(get_current_async!(socket, key), {:error, reason})}
          end

        Phoenix.Component.assign(socket, new_assigns)

      {:exit, _reason} = normalized_exit ->
        new_assigns =
          for key <- keys do
            {key, AsyncResult.failed(get_current_async!(socket, key), normalized_exit)}
          end

        Phoenix.Component.assign(socket, new_assigns)
    end
  end

  # handle race of async being canceled and then reassigned
  defp prune_current_async(socket, keys, ref) do
    case get_private_async(socket, keys) do
      {^ref, _pid, _kind} -> {:ok, update_private_async(socket, &Map.delete(&1, keys))}
      {_ref, _pid, _kind} -> :error
      nil -> :error
    end
  end

  defp update_private_async(socket, func) do
    existing = socket.private[:phoenix_async] || %{}
    Phoenix.LiveView.put_private(socket, :phoenix_async, func.(existing))
  end

  defp get_private_async(%Socket{} = socket, key) do
    socket.private[:phoenix_async][key]
  end

  defp get_current_async!(socket, key) do
    # handle case where assign is temporary and needs to be rebuilt
    case socket.assigns do
      %{^key => %AsyncResult{} = current_async} -> current_async
      %{^key => _other} -> AsyncResult.loading(key)
      %{} -> raise ArgumentError, "missing async assign #{inspect(key)}"
    end
  end

  defp to_exit(:throw, reason, stack), do: {:exit, {{:nocatch, reason}, stack}}
  defp to_exit(:error, reason, stack), do: {:exit, {reason, stack}}
  defp to_exit(:exit, reason, _stack), do: {:exit, reason}

  defp cancel_existing(%Socket{} = socket, key) do
    if get_private_async(socket, key) do
      Phoenix.LiveView.cancel_async(socket, key)
    else
      socket
    end
  end

  defp cid(%Socket{} = socket) do
    if myself = socket.assigns[:myself], do: myself.cid
  end
end

defmodule ExRabbitMQ.AST.Common do
  @moduledoc false
  # @moduledoc """
  # AST holding module for the consumer and producer behaviours.
  # """

  @doc """
  Produces the common part of the AST for both the consumer and producer behaviours.

  Specifically, it holds getters and setters, using the process dictionary, to hold important information such as the channel
  pid and monitor reference.

  It also holds the AST necessary to open a channel when an AMQP connection is ready.
  """
  def ast() do
    # credo:disable-for-previous-line
    quote location: :keep do

      alias ExRabbitMQ.Connection.Config, as: ConnectionConfig

      def xrmq_channel_setup(_channel, state) do
        {:ok, state}
      end

      def xrmq_channel_open(_channel, state) do
        {:ok, state}
      end

      def xrmq_basic_cancel(cancellation_info, state) do
        Logger.error("received basic_cancel message", cancellation_info: cancellation_info)

        {:stop, :basic_cancel, state}
      end

      def xrmq_get_env_config(key) do
        Application.get_env(:exrabbitmq, key)
      end

      def xrmq_get_connection_config() do
        Process.get(Constants.connection_config_key())
      end

      def xrmq_basic_publish(payload, exchange, routing_key, opts \\ []) do
        with\
          {channel, _} when channel !== nil <- xrmq_get_channel_info(),
          :ok <- AMQP.Basic.publish(channel, exchange, routing_key, payload, opts) do
          :ok
        else
          {nil, _} -> {:error, Constants.no_channel_error()}
          error -> {:error, error}
        end
      end

      def xrmq_extract_state({:ok, new_state}) do
        new_state
      end

      def xrmq_extract_state({:error, _, new_state}) do
        new_state
      end

      defp xrmq_get_connection_config(key) do
        config = xrmq_get_env_config(key)

        %ConnectionConfig{
          username: config[:username],
          password: config[:password],
          host: config[:host],
          port: config[:port],
          vhost: config[:vhost],
          heartbeat: config[:heartbeat],
          reconnect_after: config[:reconnect_after],
        }
      end

      defp xrmq_set_connection_config_defaults(%ConnectionConfig{} = config) do
        %ConnectionConfig{
          username: config.username,
          password: config.password,
          host: config.host,
          port: config.port || 5672,
          vhost: config.vhost || "/",
          heartbeat: config.heartbeat || 1000,
          reconnect_after: config.reconnect_after || 2000,
        }
      end

      defp xrmq_set_connection_config(config) do
        Process.put(Constants.connection_config_key(), config)
      end

      defp xrmq_get_connection_pid() do
        Process.get(Constants.connection_pid_key())
      end

      defp xrmq_set_connection_pid(connection_pid) do
        Process.put(Constants.connection_pid_key(), connection_pid)
      end

      defp xrmq_set_channel_ripper_pid(channel_ripper_pid) do
        Process.put(Constants.channel_ripper_pid_key(), channel_ripper_pid)
      end

      defp xrmq_get_channel_ripper_pid() do
        Process.get(Constants.channel_ripper_pid_key())
      end

      defp xrmq_get_channel_info() do
        {Process.get(Constants.channel_key()), Process.get(Constants.channel_monitor_key())}
      end

      defp xrmq_set_channel_info(channel, channel_monitor) do
        Process.put(Constants.channel_key(), channel)
        Process.put(Constants.channel_monitor_key(), channel_monitor)
      end

      defp xrmq_open_channel(state) do
        case Connection.get(xrmq_get_connection_pid()) do
          {:ok, connection} ->
            case AMQP.Channel.open(connection) do
              {:ok, %AMQP.Channel{pid: pid} = channel} ->
                ChannelRipper.set_channel(xrmq_get_channel_ripper_pid(), channel)

                channel_monitor = Process.monitor(pid)

                xrmq_set_channel_info(channel, channel_monitor)

                Logger.debug("opened a new channel")

                with {:ok, state} <- xrmq_channel_setup(channel, state) do
                  xrmq_channel_open(channel, state)
                end
              :closing ->
                xrmq_set_channel_info(nil, nil)

                {:error, :closing, state}
              error ->
                Logger.error("could not open a new channel: #{inspect(error)}")

                xrmq_set_channel_info(nil, nil)

                Process.exit(self(), {:xrmq_channel_open_error, error})

                {:error, error, state}
            end
          {:error, reason} ->
            {:error, reason, state}
        end
      end

      defoverridable xrmq_channel_setup: 2, xrmq_channel_open: 2
    end
  end
end

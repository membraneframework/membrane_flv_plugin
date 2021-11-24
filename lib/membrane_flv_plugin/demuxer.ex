defmodule Membrane.FLV.Demuxer do
  @moduledoc """
  Element for demuxing FLV streams into audio and video streams.
  FLV format supports only one video and audio stream.
  They are optional however, FLV without either audio or video is also possible.

  When a new FLV stream is detected, you will be notified with `Membrane.FLV.Demuxer.new_stream_notification()`.

  If you want to pre-link the pipeline and skip handling notifications, make sure use the following output pads:
  - `Pad.ref(:audio, 0)` for audio stream
  - `Pad.ref(:video, 0)` for video stream
  """
  use Membrane.Filter
  use Bunch

  require Membrane.Logger

  alias Membrane.RemoteStream
  alias Membrane.FLV.Parser
  alias Membrane.{Buffer, FLV}

  @typedoc """
  Type of notification that is sent when a new FLV stream is detected.
  """
  @type new_stream_notification_t() :: {:new_stream, Membrane.Pad.ref_t(), codec_t()}

  @typedoc """
  List of formats supported by the demuxer.

  For video, only H264 is supported
  Audio codecs other than AAC might not work correctly, although they won't throw any errors.
  """
  @type codec_t() :: FLV.audio_format_t() | :H264

  def_input_pad :input,
    availability: :always,
    caps: {RemoteStream, content_format: FLV, type: :bytestream},
    mode: :pull,
    demand_unit: :buffers

  def_output_pad :audio,
    availability: :on_request,
    caps: [RemoteStream, RemoteStream.AAC],
    mode: :pull

  def_output_pad :video,
    availability: :on_request,
    caps: {RemoteStream.H264, stream_format: :byte_stream},
    mode: :pull

  @impl true
  def handle_init(_opts) do
    {:ok, %{partial: <<>>, pads_buffer: %{}, aac_asc: <<>>, header_present?: true}}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_demand(_pad, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload}, _ctx, %{header_present?: true} = state) do
    case Membrane.FLV.Parser.parse_header(state.partial <> payload) do
      {:ok, _header, rest} ->
        {{:ok, demand: :input}, %{state | partial: rest, header_present?: false}}

      {:error, :not_enough_data} ->
        {{:ok, demand: :input}, %{state | partial: state.partial <> payload}}

      {:error, :not_a_header} ->
        raise("Invalid data detected on the input. Expected FLV header")
    end
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload}, _ctx, %{header_present?: false} = state) do
    case Parser.parse_body(state.partial <> payload) do
      {:ok, frames, rest} ->
        {actions, state} = get_actions(frames, state)
        actions = Enum.concat(actions, demand: :input)
        {{:ok, actions}, %{state | partial: rest}}

      {:error, :not_enough_data} ->
        {{:ok, demand: :input}, %{state | partial: state.partial <> payload}}
    end
  end

  @impl true
  def handle_pad_added(pad, _ctx, state) do
    actions = Map.get(state.pads_buffer, pad, []) |> Enum.to_list()
    state = put_in(state, [:pads_buffer, pad], :connected)
    {{:ok, actions}, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    result =
      state.pads_buffer
      |> Enum.map(fn {pad, value} ->
        if value == :connected do
          {[end_of_stream: pad], {pad, value}}
        else
          {[], {pad, Qex.push(value, {:end_of_stream, pad})}}
        end
      end)

    actions = Enum.flat_map(result, &elem(&1, 0))
    pads_buffer = Enum.map(result, &elem(&1, 1)) |> Enum.into(%{})

    {{:ok, actions}, %{state | pads_buffer: pads_buffer}}
  end

  defp get_actions(frames, original_state) do
    Enum.reduce(frames, {[], original_state}, fn %{type: type} = packet, {actions, state} ->
      pad = pad(packet)

      cond do
        type == :audio_config and packet.codec == :AAC ->
          Membrane.Logger.debug("Audio configuration received")
          {:caps, {pad, %RemoteStream.AAC{audio_specific_config: packet.payload}}}

        type == :video_config and packet.codec == :H264 ->
          Membrane.Logger.debug("Video configuration received")

          {:caps,
           {pad,
            %RemoteStream.H264{
              decoder_configuration_record: packet.payload,
              stream_format: :byte_stream
            }}}

        type == :audio_config ->
          [
            caps: {pad, %RemoteStream{content_format: packet.codec}},
            buffer: {pad, %Buffer{payload: get_payload(packet, state)}}
          ]

        true ->
          buffer = %Buffer{payload: get_payload(packet, state)}
          {:buffer, {pad, buffer}}
      end
      |> buffer_or_send(packet, state)
      |> then(fn {out_actions, state} -> {actions ++ out_actions, state} end)
    end)
  end

  defp buffer_or_send(actions, packet, state) when is_list(actions) do
    Enum.reduce(actions, {[], state}, fn action, {actions, state} ->
      {out_actions, state} = buffer_or_send(action, packet, state)
      {actions ++ out_actions, state}
    end)
  end

  defp buffer_or_send(action, packet, state) when not is_list(action) do
    pad = pad(packet)

    cond do
      match?(%{^pad => :connected}, state.pads_buffer) ->
        {Bunch.listify(action), state}

      Map.has_key?(state.pads_buffer, pad(packet)) ->
        state = update_in(state, [:pads_buffer, pad(packet)], &Qex.push(&1, action))
        {[], state}

      true ->
        state = put_in(state, [:pads_buffer, pad(packet)], Qex.new([action]))
        {notify_about_new_stream(packet), state}
    end
  end

  defp get_payload(%FLV.Packet{type: :video, codec: :H264} = packet, _state) do
    Membrane.AVC.Utils.to_annex_b(packet.payload)
  end

  defp get_payload(packet, _state), do: packet.payload

  defp notify_about_new_stream(packet) do
    [notify: {:new_stream, pad(packet), packet.codec}]
  end

  defp pad(%FLV.Packet{type: type, stream_id: stream_id}) when type in [:audio_config, :audio],
    do: Pad.ref(:audio, stream_id)

  defp pad(%FLV.Packet{type: type, stream_id: stream_id}) when type in [:video_config, :video],
    do: Pad.ref(:video, stream_id)
end

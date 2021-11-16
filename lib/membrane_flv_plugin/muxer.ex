defmodule Membrane.FLV.Muxer do
  @moduledoc """
  FLV container muxer
  """
  use Membrane.Filter
  alias Membrane.{AAC, FLV, Buffer}
  alias Membrane.FLV.{Header, Packet, Serializer}

  def_input_pad :audio,
    availability: :on_request,
    caps: {AAC, encapsulation: :none},
    mode: :pull,
    demand_unit: :buffers

  def_input_pad :video,
    availability: :on_request,
    caps: Membrane.MP4.Payload,
    mode: :pull,
    demand_unit: :buffers

  def_output_pad :output,
    availability: :always,
    caps: {Membrane.RemoteStream, content_format: FLV},
    mode: :pull

  def_options audio_present?: [
                spec: boolean(),
                default: true
              ],
              video_present?: [
                spec: boolean(),
                default: true
              ]

  @impl true
  def handle_init(%__MODULE__{} = opts) do
    {:ok,
     Map.merge(Map.from_struct(opts), %{
       last_item_size: 0,
       timestamps: %{},
       header_sent: false
     })}
  end

  @impl true
  def handle_pad_added(pad, ctx, state) do
    state = put_in(state, [:timestamps, pad], 0)

    if ctx.playback_state == :playing do
      {{:ok, redemand: :output}, state}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {pad, _pts} = Enum.min_by(state.timestamps, &Bunch.value/1)
    {{:ok, demand: {pad, size}}, state}
  end

  @impl true
  def handle_process(Pad.ref(type, stream_id) = pad, buffer, ctx, state) do
    if ctx.pads[pad].caps == nil,
      do: raise("Caps must be sent before sending a packet you blithering idiot")

    timestamp = get_timestamp(buffer)
    state = put_in(state, [:timestamps, pad], timestamp)

    %Packet{
      type: type,
      stream_id: stream_id,
      payload: buffer.payload,
      codec: codec(type),
      timestamp: timestamp
    }
    |> handle_segment(ctx, state)
  end

  @impl true
  def handle_caps(Pad.ref(:audio, stream_id), %AAC{} = caps, ctx, state) do
    %Packet{
      type: :audio_config,
      stream_id: stream_id,
      payload: Serializer.acc_to_audio_specific_config(caps),
      codec: :AAC,
      timestamp: 0
    }
    |> handle_segment([], ctx, state)
  end

  @impl true
  def handle_caps(
        Pad.ref(:video, stream_id),
        %Membrane.MP4.Payload{content: %Membrane.MP4.Payload.AVC1{avcc: config}} = _caps,
        ctx,
        state
      ) do
    %Packet{
      type: :video_config,
      stream_id: stream_id,
      payload: config,
      codec: :H264,
      timestamp: 0
    }
    |> handle_segment(ctx, state)
  end

  @impl true
  def handle_caps(Pad.ref(type, _id) = _pad, caps, _ctx, _state),
    do: raise("Caps `#{inspect(caps)}` are not supported for stream type #{inspect(type)}")

  defp codec(:audio), do: :AAC
  defp codec(:video), do: :H264

  defp get_timestamp(buffer),
    do:
      Ratio.floor(buffer.metadata.timestamp)
      |> Membrane.Time.as_milliseconds()
      |> Ratio.floor()

  defp handle_segment(segment, additional_actions \\ [redemand: :output], ctx, state) do
    {header_action, state} = maybe_send_header(ctx, state)
    {packet_action, state} = do_handle_segment(segment, state)

    actions =
      Enum.concat([
        header_action,
        packet_action,
        additional_actions
      ])

    {{:ok, actions}, state}
  end

  defp maybe_send_header(_ctx, %{header_sent: true} = state), do: {[], state}

  defp maybe_send_header(ctx, state) do
    {actions, state} =
      %Header{
        audio_present?: state.audio_present? or has_stream?(:audio, ctx),
        video_present?: state.video_present? or has_stream?(:video, ctx)
      }
      |> do_handle_segment(state)

    state = Map.put(state, :header_sent, true)
    {actions, state}
  end

  defp do_handle_segment(segment, state) do
    {packet, last_item_size} = Serializer.serialize(segment, state.last_item_size)
    state = Map.put(state, :last_item_size, last_item_size)
    {[buffer: {:output, %Buffer{payload: packet}}], state}
  end

  defp has_stream?(type, ctx), do: ctx.pads |> Enum.any?(&match?({Pad.ref(^type, _), _value}, &1))
end

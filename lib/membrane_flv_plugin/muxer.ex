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
       params_sent: MapSet.new(),
       last_item_size: 0,
       timestamps: %{}
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
  def handle_prepared_to_playing(_ctx, state) do
    %Header{
      audio_present?: state.audio_present?,
      video_present?: state.video_present?
    }
    |> handle_segment(state)
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
    |> handle_segment(state)
  end

  @impl true
  def handle_caps(Pad.ref(:audio, stream_id), %AAC{} = caps, _ctx, state) do
    %Packet{
      type: :audio_config,
      stream_id: stream_id,
      payload: Serializer.acc_to_audio_specific_config(caps),
      codec: :AAC,
      timestamp: 0
    }
    |> handle_segment([], state)
  end

  @impl true
  def handle_caps(
        Pad.ref(:video, stream_id),
        %Membrane.MP4.Payload{content: %Membrane.MP4.Payload.AVC1{avcc: config}} = _caps,
        _ctx,
        state
      ) do
    %Packet{
      type: :video_config,
      stream_id: stream_id,
      payload: config,
      codec: :H264,
      timestamp: 0
    }
    |> handle_segment(state)
  end

  @impl true
  def handle_caps(_pad, _caps, _ctx, _state), do: raise("No chyba Cie pojebało")

  defp codec(:audio), do: :AAC
  defp codec(:video), do: :H264

  defp get_timestamp(buffer),
    do:
      Ratio.floor(buffer.metadata.timestamp)
      |> Membrane.Time.as_milliseconds()
      |> Ratio.floor()

  defp handle_segment(segment, additional_actions \\ [redemand: :output], state) do
    {packet, last_item_size} = Serializer.serialize(segment, state.last_item_size)
    state = Map.put(state, :last_item_size, last_item_size)
    actions = Enum.concat([buffer: {:output, %Buffer{payload: packet}}], additional_actions)
    {{:ok, actions}, state}
  end
end

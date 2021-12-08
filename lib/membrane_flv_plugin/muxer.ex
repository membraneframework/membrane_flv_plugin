defmodule Membrane.FLV.Muxer do
  @moduledoc """
  Element for muxing AAC and H264 streams into FLV format. It only supports one video and one audio stream.
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

  @impl true
  def handle_init(_opts) do
    {:ok,
     %{
       previous_tag_size: 0,
       timestamps: %{},
       header_sent: false
     }}
  end

  @impl true
  def handle_pad_added(Pad.ref(_type, stream_id), _ctx, _state) when stream_id != 0,
    do: raise(ArgumentError, message: "Stream id must always be 0")

  @impl true
  def handle_pad_added(_pad, ctx, _state) when ctx.playback_state == :playing,
    do: raise("Adding pads after transition to state :playing is not allowed")

  @impl true
  def handle_pad_added(Pad.ref(_type, 0) = pad, _ctx, state) do
    state = put_in(state, [:timestamps, pad], 0)
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(ctx, state) do
    {actions, state} =
      %Header{
        audio_present?: has_stream?(:audio, ctx),
        video_present?: has_stream?(:video, ctx)
      }
      |> prepare_to_send(state)

    demand_actions =
      ctx.pads |> Map.drop([Pad.ref(:output)]) |> Map.keys() |> Enum.flat_map(&[demand: {&1, 1}])

    actions = Enum.concat(actions, demand_actions)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, state) do
    # We will request one buffer from the stream that has the lowest timestamp
    # This will ensure that the output stream has reasonable audio / video balance
    {pad, _pts} = Enum.min_by(state.timestamps, &Bunch.value/1)
    {{:ok, [demand: {pad, 1}]}, state}
  end

  @impl true
  def handle_process(Pad.ref(type, stream_id) = pad, buffer, ctx, state) do
    if ctx.pads[pad].caps == nil,
      do: raise("Caps must be sent before sending a packet")

    state = put_in(state, [:timestamps, pad], buffer.pts)

    {actions, state} =
      %Packet{
        type: type,
        stream_id: stream_id,
        payload: buffer.payload,
        codec: codec(type),
        pts: get_timestamp(buffer.pts || buffer.dts),
        dts: get_timestamp(buffer.dts || buffer.pts),
        frame_type:
          if(type == :audio,
            do: :keyframe,
            else: if(buffer.metadata.h264.key_frame?, do: :keyframe, else: :interframe)
          )
      }
      |> prepare_to_send(state)

    {{:ok, actions ++ [redemand: :output]}, state}
  end

  @impl true
  def handle_caps(Pad.ref(:audio, stream_id) = pad, %AAC{} = caps, _ctx, state) do
    timestamp = Map.get(state.timestamps, pad, 0) |> get_timestamp()

    %Packet{
      type: :audio_config,
      stream_id: stream_id,
      payload: Serializer.aac_to_audio_specific_config(caps),
      codec: codec(:audio),
      pts: timestamp,
      dts: timestamp
    }
    |> prepare_to_send(state)
    |> then(fn {actions, state} -> {{:ok, actions}, state} end)
  end

  @impl true
  def handle_caps(
        Pad.ref(:video, stream_id) = pad,
        %Membrane.MP4.Payload{content: %Membrane.MP4.Payload.AVC1{avcc: config}} = _caps,
        _ctx,
        state
      ) do
    timestamp = Map.get(state.timestamps, pad, 0) |> get_timestamp()

    %Packet{
      type: :video_config,
      stream_id: stream_id,
      payload: config,
      codec: codec(:video),
      pts: timestamp,
      dts: timestamp
    }
    |> prepare_to_send(state)
    |> then(fn {actions, state} -> {{:ok, actions}, state} end)
  end

  @impl true
  def handle_caps(Pad.ref(type, _id) = _pad, caps, _ctx, _state),
    do: raise("Caps `#{inspect(caps)}` are not supported for stream type #{inspect(type)}")

  @impl true
  def handle_end_of_stream(pad, ctx, state) do
    # Check if there are any input pads that didn't eos. If not, send end of stream on output
    state = Map.update!(state, :timestamps, &Map.delete(&1, pad))

    if Enum.any?(ctx.pads, &match?({_, %{direction: :input, end_of_stream?: false}}, &1)) do
      {:ok, state}
    else
      last = <<state.previous_tag_size::32>>
      {{:ok, buffer: {:output, %Buffer{payload: last}}, end_of_stream: :output}, state}
    end
  end

  defp codec(:audio), do: :AAC
  defp codec(:video), do: :H264

  defp get_timestamp(timestamp) when is_nil(timestamp), do: nil

  defp get_timestamp(timestamp),
    do:
      Ratio.floor(timestamp)
      |> Membrane.Time.as_milliseconds()
      |> Ratio.floor()

  defp prepare_to_send(segment, state) do
    {tag, previous_tag_size} = Serializer.serialize(segment, state.previous_tag_size)
    actions = [buffer: {:output, %Buffer{payload: tag}}]
    state = Map.put(state, :previous_tag_size, previous_tag_size)
    {actions, state}
  end

  defp has_stream?(type, ctx), do: ctx.pads |> Enum.any?(&match?({Pad.ref(^type, _), _value}, &1))
end

defmodule Membrane.FLV.Muxer do
  @moduledoc """
  Element for muxing AAC and H264 streams into FLV format.

  Input pads are dynamic, but you nend to connect them before transitioning to state `playing`.

  Due to limitations of the FLV format, only one audio and one video stream can be muxed and they both need to have a stream_id of 0.
  Therefore, please make sure you only use the following pads:
  - `Pad.ref(:audio, 0)`
  - `Pad.ref(:video, 0)`
  """
  use Membrane.Filter

  require Membrane.H264
  alias Membrane.{AAC, Buffer, FLV, H264, RemoteStream, TimestampQueue}
  alias Membrane.FLV.{Header, Packet, Serializer}

  def_input_pad :audio,
    availability: :on_request,
    accepted_format: %AAC{encapsulation: :none, config: {:audio_specific_config, _config}}

  def_input_pad :video,
    availability: :on_request,
    accepted_format: %H264{stream_structure: structure} when H264.is_avc(structure)

  def_output_pad :output,
    availability: :always,
    accepted_format: %Membrane.RemoteStream{content_format: FLV}

  @impl true
  def handle_init(_ctx, _opts) do
    queue =
      TimestampQueue.new(
        pause_demand_boundary: {:time, Membrane.Time.milliseconds(100)},
        synchronization_strategy: :explicit_offsets
      )

    {[],
     %{
       previous_tag_size: 0,
       init_dts: %{},
       last_dts: %{},
       header_sent: false,
       queue: queue
     }}
  end

  @impl true
  def handle_pad_added(Pad.ref(_type, stream_id), _ctx, _state) when stream_id != 0,
    do: raise(ArgumentError, message: "Stream id must always be 0")

  @impl true
  def handle_pad_added(_pad, ctx, _state) when ctx.playback == :playing,
    do: raise("Adding pads after transition to state :playing is not allowed")

  @impl true
  def handle_pad_added(Pad.ref(_type, 0) = pad, _ctx, state) do
    queue = TimestampQueue.register_pad(state.queue, pad)
    {[], %{state | queue: queue}}
  end

  @impl true
  def handle_playing(ctx, state) do
    {actions, state} =
      %Header{
        audio_present?: has_stream?(:audio, ctx),
        video_present?: has_stream?(:video, ctx)
      }
      |> prepare_to_send(state)

    {[stream_format: {:output, %RemoteStream{content_format: FLV}}] ++ actions, state}
  end

  @impl true
  def handle_event(:output, event, _ctx, state) do
    {[forward: event], state}
  end

  @impl true
  def handle_event(input_pad, event, _ctx, state) do
    state.queue
    |> TimestampQueue.push_event(input_pad, event)
    |> TimestampQueue.pop_available_items()
    |> handle_queue_output(state)
  end

  @impl true
  def handle_buffer(pad, buffer, _ctx, state) do
    state.queue
    |> TimestampQueue.push_buffer_and_pop_available_items(pad, buffer)
    |> handle_queue_output(state)
  end

  @impl true
  def handle_stream_format(pad, format, _ctx, state) do
    state.queue
    |> TimestampQueue.push_stream_format(pad, format)
    |> TimestampQueue.pop_available_items()
    |> handle_queue_output(state)
  end

  @impl true
  def handle_end_of_stream(pad, _ctx, state) do
    state.queue
    |> TimestampQueue.push_end_of_stream(pad)
    |> TimestampQueue.pop_available_items()
    |> handle_queue_output(state)
  end

  defp handle_queue_output({suggested_actions, items, queue}, state) do
    state = %{state | queue: queue}
    {actions, state} = Enum.flat_map_reduce(items, state, &handle_queue_item/2)
    {suggested_actions ++ actions, state}
  end

  defp handle_queue_item({_input_pad, {:event, event}}, state) do
    {[event: {:output, event}], state}
  end

  defp handle_queue_item({pad, {:buffer, buffer}}, state) do
    Pad.ref(type, stream_id) = pad

    dts = get_timestamp(buffer.dts || buffer.pts)
    pts = get_timestamp(buffer.pts) || dts

    {dts, pts, state} =
      case state.init_dts[pad] do
        # FLV requires DTS to start from 0
        nil -> {0, pts - dts, put_in(state, [:init_dts, pad], dts)}
        init_dts -> {dts - init_dts, pts - init_dts, state}
      end

    state = put_in(state, [:last_dts, pad], dts)

    %Packet{
      type: type,
      stream_id: stream_id,
      payload: buffer.payload,
      codec: codec(type),
      pts: pts,
      dts: dts,
      frame_type:
        if(type == :audio or buffer.metadata.h264.key_frame?, do: :keyframe, else: :interframe)
    }
    |> prepare_to_send(state)
  end

  defp handle_queue_item(
         {Pad.ref(:audio, stream_id) = pad,
          {:stream_format, %AAC{config: {:audio_specific_config, config}}}},
         state
       ) do
    timestamp = Map.get(state.last_dts, pad, 0) |> get_timestamp()

    %Packet{
      type: :audio_config,
      stream_id: stream_id,
      payload: config,
      codec: codec(:audio),
      pts: timestamp,
      dts: timestamp
    }
    |> prepare_to_send(state)
  end

  defp handle_queue_item(
         {Pad.ref(:video, stream_id) = pad,
          {:stream_format, %H264{stream_structure: {:avc1, dcr}}}},
         state
       ) do
    timestamp = Map.get(state.last_dts, pad, 0) |> get_timestamp()

    %Packet{
      type: :video_config,
      stream_id: stream_id,
      payload: dcr,
      codec: codec(:video),
      pts: timestamp,
      dts: timestamp
    }
    |> prepare_to_send(state)
  end

  defp handle_queue_item({Pad.ref(type, _id), {:stream_format, stream_format}}, _state) do
    raise """
    Stream format '#{inspect(stream_format)}' is not supported for stream type #{inspect(type)}"
    """
  end

  defp handle_queue_item({_pad, :end_of_stream}, state) do
    if TimestampQueue.pads(state.queue) |> MapSet.size() == 0 do
      last = <<state.previous_tag_size::32>>
      {[buffer: {:output, %Buffer{payload: last}}, end_of_stream: :output], state}
    else
      {[], state}
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

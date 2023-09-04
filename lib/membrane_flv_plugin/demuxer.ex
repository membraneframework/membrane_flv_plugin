defmodule Membrane.FLV.Demuxer do
  @moduledoc """
  Element for demuxing FLV streams into audio and video streams.
  FLV format supports only one video and audio stream.
  They are optional however, FLV without either audio or video is also possible.

  When a new FLV stream is detected, you will be notified with `Membrane.FLV.Demuxer.new_stream_notification()`.

  If you want to pre-link the pipeline and skip handling notifications, make sure use the following output pads:
  - `Pad.ref(:audio, 0)` for audio stream
  - `Pad.ref(:video, 0)` for video stream

  ## Note
  The demuxer implements the [Enhanced RTMP specification](https://github.com/veovera/enhanced-rtmp) in terms of parsing.
  It does NOT support processing of the protocols other than H264 and AAC.

  """
  use Membrane.Filter
  use Bunch

  require Membrane.Logger

  alias Membrane.{AAC, Buffer, FLV, H264}
  alias Membrane.FLV.Parser
  alias Membrane.RemoteStream

  @typedoc """
  Type of notification that is sent when a new FLV stream is detected.
  """
  @type new_stream_notification_t() :: {:new_stream, Membrane.Pad.ref(), codec_t()}

  @typedoc """
  List of formats supported by the demuxer.

  For video, only H264 is supported
  Audio codecs other than AAC might not work correctly, although they won't throw any errors.
  """
  @type codec_t() :: FLV.audio_codec_t() | :H264

  def_input_pad :input,
    availability: :always,
    accepted_format:
      %RemoteStream{content_format: content_format, type: :bytestream}
      when content_format in [nil, FLV],
    mode: :pull,
    demand_unit: :buffers

  def_output_pad :audio,
    availability: :on_request,
    accepted_format:
      any_of(
        RemoteStream,
        %AAC{encapsulation: :none, config: {:audio_specific_config, _config}}
      ),
    mode: :pull

  def_output_pad :video,
    availability: :on_request,
    accepted_format: %H264{stream_structure: {:avc3, _dcr}},
    mode: :pull

  @impl true
  def handle_init(_ctx, _opts) do
    {[],
     %{
       partial: <<>>,
       pads_buffer: %{},
       aac_asc: <<>>,
       header_present?: true,
       ignored_packets: 0
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: :input], state}
  end

  @impl true
  def handle_demand(_pad, size, :buffers, _ctx, state) do
    {[demand: {:input, size}], state}
  end

  @impl true
  def handle_stream_format(_pad, _stream_format, _context, state), do: {[], state}

  @max_ignored_packets 300
  @impl true
  def handle_process(:input, _buffer, _ctx, %{ignored_packets: ignored_packets} = state)
      when ignored_packets > 0 do
    if ignored_packets >= @max_ignored_packets do
      raise "Too many ignored packets..."
    end

    {[], %{state | ignored_packets: ignored_packets + 1}}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload}, _ctx, %{header_present?: true} = state) do
    case Membrane.FLV.Parser.parse_header(state.partial <> payload) do
      {:ok, _header, rest} ->
        {[demand: :input], %{state | partial: rest, header_present?: false}}

      {:error, :not_enough_data} ->
        {[demand: :input], %{state | partial: state.partial <> payload}}

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
        {actions, %{state | partial: rest}}

      {:error, :not_enough_data} ->
        {[demand: :input], %{state | partial: state.partial <> payload}}

      {:error, {:unsupported_codec, codec}} ->
        {[notify_parent: {:unsupported_codec, codec}],
         %{ignored_packets: state.ignored_packets + 1}}
    end
  end

  @impl true
  def handle_pad_added(pad, _ctx, state) do
    actions = Map.get(state.pads_buffer, pad, []) |> Enum.to_list()
    state = put_in(state, [:pads_buffer, pad], :connected)
    {actions, state}
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

    {actions, %{state | pads_buffer: pads_buffer}}
  end

  defp get_actions(frames, original_state) do
    Enum.reduce(frames, {[], original_state}, fn %{type: type} = packet, {actions, state} ->
      pad = pad(packet)

      pts = Membrane.Time.milliseconds(packet.pts)
      dts = Membrane.Time.milliseconds(packet.dts)

      cond do
        type == :audio_config and packet.codec == :AAC ->
          Membrane.Logger.debug("Audio configuration received")

          {[stream_format: {pad, %AAC{config: {:audio_specific_config, packet.payload}}}], state}

        type == :audio_config ->
          {[
             stream_format: {pad, %RemoteStream{content_format: packet.codec}},
             buffer: {pad, %Buffer{pts: pts, dts: dts, payload: packet.payload}}
           ], state}

        type == :video_config and packet.codec == :H264 ->
          Membrane.Logger.debug("Video configuration received")

          {[
             stream_format:
               {pad, %H264{alignment: :au, stream_structure: {:avc3, packet.payload}}}
           ], state}

        type == :video_config and packet.codec in [:AV1, :HEVC, :VP9] ->
          {[notify_parent: {:unsupported_codec, packet.codec}],
           %{state | ignored_packets: state.ignored_packets + 1}}

        true ->
          buffer = %Buffer{
            pts: pts,
            dts: dts,
            metadata: get_metadata(packet),
            payload: packet.payload
          }

          {[buffer: {pad, buffer}], state}
      end
      |> buffer_or_send(packet)
      |> then(fn {out_actions, state} -> {actions ++ out_actions, state} end)
    end)
  end

  defp buffer_or_send({actions, state}, packet) do
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

      Map.has_key?(state.pads_buffer, pad) ->
        state = update_in(state, [:pads_buffer, pad], &Qex.push(&1, action))
        {[], state}

      true ->
        state = put_in(state, [:pads_buffer, pad(packet)], Qex.new([action]))
        {notify_about_new_stream(packet), state}
    end
  end

  defp notify_about_new_stream(packet) do
    [notify_parent: {:new_stream, pad(packet), packet.codec}]
  end

  defp get_metadata(%FLV.Packet{type: :video, codec_params: %{key_frame?: key_frame?}}),
    do: %{key_frame?: key_frame?}

  defp get_metadata(_packet), do: %{}

  defp pad(%FLV.Packet{type: type, stream_id: stream_id}) do
    type =
      case type do
        :audio -> :audio
        :audio_config -> :audio
        :video -> :video
        :video_config -> :video
      end

    Pad.ref(type, stream_id)
  end
end

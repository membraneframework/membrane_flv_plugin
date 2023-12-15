defmodule Membrane.FLV.Parser do
  @moduledoc false

  alias Membrane.FLV
  alias Membrane.FLV.{Header, Packet}

  @spec parse_header(binary()) :: {:ok, Header.t(), binary()} | {:error, reason :: any()}
  def parse_header(
        <<"FLV", 0x01::8, 0::5, type_flags_audio::1, 0::1, type_flags_video::1, data_offset::32,
          _body::binary>> = data
      ) do
    case data do
      <<_header::binary-size(data_offset), rest::binary>> ->
        %Header{
          audio_present?: type_flags_audio == 1,
          video_present?: type_flags_video == 1
        }
        |> then(&{:ok, &1, rest})

      _else ->
        {:error, :not_enough_data}
    end
  end

  def parse_header(data) when byte_size(data) < 9, do: {:error, :not_enough_data}
  def parse_header(_incorrect_data), do: {:error, :not_a_header}

  @spec parse_body(binary()) ::
          {:ok, packets :: [Packet.t()], rest :: binary()}
          | {:error, :not_enough_data}
          | {:error, {:unsupported_codec, FLV.video_codec_t()}}
  def parse_body(data) when byte_size(data) < 15, do: {:error, :not_enough_data}

  def parse_body(<<_head::40, data_size::24, _rest::binary>> = data)
      when byte_size(data) < data_size + 15,
      do: {:error, :not_enough_data}

  # script data - ignoring it and continuing with following TAGs
  def parse_body(
        <<_head::32, _reserved::2, 0::1, 18::5, data_size::24, _timestamp::24,
          _timestamp_extended::8, _stream_id::24, _payload::binary-size(data_size), rest::binary>>
      ),
      do: parse_body(rest)

  # proper TAG
  def parse_body(<<
        _previous_tag_size::32,
        _reserved::2,
        0::1,
        type::5,
        data_size::24,
        timestamp::24,
        timestamp_extended::8,
        stream_id::24,
        payload::binary-size(data_size),
        rest::binary
      >>) do
    type = resolve_type(type)

    with {:ok, {type, codec, codec_params, payload}} <- parse_payload(type, payload) do
      dts = parse_timestamp(timestamp, timestamp_extended)
      # if composition time is not set in codec_params, then we assume it's 0
      pts = dts + Map.get(codec_params, :composition_time, 0)

      packet = %Packet{
        pts: pts,
        dts: dts,
        stream_id: stream_id,
        type: type,
        payload: payload,
        codec: codec,
        codec_params: codec_params
      }

      case parse_body(rest) do
        {:ok, packets, rest} ->
          {:ok, [packet | packets], rest}

        {:error, :not_enough_data} ->
          {:ok, [packet], rest}
      end
    end
  end

  def parse_body(_too_little_data), do: {:error, :not_enough_data}

  # AAC
  # Ignore parameters set in the header. They are supposed to be extracted from Audio Specific Config
  defp parse_payload(
         :audio,
         <<10::4, 3::2, _sound_size::1, 1::1, packet_type::8, payload::binary>>
       ) do
    type = if packet_type == 1, do: :audio, else: :audio_config
    {:ok, {type, :AAC, %{}, payload}}
  end

  # everything else
  defp parse_payload(:audio, <<
         sound_format::4,
         sound_rate::2,
         _sound_size::1,
         sound_type::1,
         payload::binary
       >>) do
    codec = FLV.index_to_sound_format(sound_format)

    sound_rate =
      case sound_rate do
        0 -> 5_500
        1 -> 11_000
        2 -> 22_050
        3 -> 44_100
      end

    sound_type =
      case sound_type do
        0 -> :mono
        1 -> :stereo
      end

    {:ok, {:audio, codec, %{sound_rate: sound_rate, sound_type: sound_type}, payload}}
  end

  # extended rtmp specification: https://github.com/veovera/enhanced-rtmp
  @keyframe_frame_type 1

  @av1 <<"a", "v", "0", "1">>
  @vp9 <<"v", "p", "0", "9">>
  @hevc <<"h", "v", "c", "1">>
  @ex_video_header <<1::1>>

  @packet_type_sequence_start 0
  @packet_type_coded_frames 1
  # @packet_type_sequence_end 2
  # @packet_type_codec_frames_x 3
  @packet_type_metadata 4
  @packet_type_mp4g2ts_sequence_start 5
  defp parse_payload(:video, <<
         @ex_video_header::bitstring,
         frame_type::3,
         packet_type::4,
         video_four_cc::4-binary,
         payload::binary
       >>) do
    type = ext_flv_packet_type(video_four_cc, packet_type)

    {composition_time, payload} =
      if video_four_cc == @hevc and packet_type == @packet_type_coded_frames do
        <<composition_time::24, payload::binary>> = payload

        {composition_time, payload}
      else
        {0, payload}
      end

    codec =
      case video_four_cc do
        @av1 -> :AV1
        @vp9 -> :VP9
        @hevc -> :HEVC
      end

    {:ok,
     {type, codec,
      %{composition_time: composition_time, key_frame?: frame_type == @keyframe_frame_type},
      payload}}
  end

  # AVC H264
  @keyframe_frame_type 1
  defp parse_payload(:video, <<
         frame_type::4,
         7::4,
         packet_type::8,
         composition_time::24,
         payload::binary
       >>) do
    type = if packet_type == 0, do: :video_config, else: :video

    {:ok,
     {type, :H264,
      %{composition_time: composition_time, key_frame?: frame_type == @keyframe_frame_type},
      payload}}
  end

  defp parse_payload(:video, <<_frame_type::4, codec::4, _rest::binary>>) do
    vcodec = FLV.index_to_video_codec(codec)
    {:error, {:unsupported_codec, vcodec}}
  end

  defp ext_flv_packet_type(video_four_cc, packet_type) do
    cond do
      packet_type == @packet_type_metadata ->
        # NOTE: payload for this packet type includes AMF encoded metadata
        :video_config

      video_four_cc == @av1 and
          packet_type in [@packet_type_sequence_start, @packet_type_mp4g2ts_sequence_start] ->
        :video_config

      video_four_cc in [@hevc, @vp9] and packet_type == @packet_type_sequence_start ->
        :video_config

      true ->
        :video
    end
  end

  defp resolve_type(8), do: :audio
  defp resolve_type(9), do: :video
  defp resolve_type(18), do: :script_data

  defp parse_timestamp(timestamp, timestamp_extended) do
    import Bitwise
    (timestamp_extended <<< 24) + timestamp
  end
end

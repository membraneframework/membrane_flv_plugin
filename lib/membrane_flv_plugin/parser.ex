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
          {:ok, packets :: [Packet.t()], rest :: binary()} | {:error, :not_enough_data}
  def parse_body(data) when byte_size(data) < 15, do: {:error, :not_enough_data}

  def parse_body(<<_head::40, data_size::24, _rest::binary>> = data)
      when byte_size(data) < data_size + 15,
      do: {:error, :not_enough_data}

  def parse_body(<<_head::96, stream_id::24, _rest::binary>>) when stream_id != 0,
    do: raise("Stream id has to be 0. Is `#{stream_id}`")

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
    {type, codec, codec_params, payload} = parse_payload(type, payload)

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

  def parse_body(_too_little_data), do: {:error, :not_enough_data}

  # AAC
  # Ignore parameters set in the header. They are supposed to be extracted from Audio Specific Config
  defp parse_payload(
         :audio,
         <<10::4, 3::2, _sound_size::1, 1::1, packet_type::8, payload::binary>>
       ) do
    type = if packet_type == 1, do: :audio, else: :audio_config
    {type, :AAC, %{}, payload}
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

    {:audio, codec, %{sound_rate: sound_rate, sound_type: sound_type}, payload}
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

    {type, :H264,
     %{composition_time: composition_time, key_frame?: frame_type == @keyframe_frame_type},
     payload}
  end

  defp parse_payload(:video, <<_frame_type::4, codec::4, _rest::binary>>) do
    vcodec = FLV.index_to_video_codec(codec) |> inspect()
    raise("Video codec #{vcodec} is not yet supported")
  end

  defp resolve_type(8), do: :audio
  defp resolve_type(9), do: :video
  defp resolve_type(18), do: :script_data

  defp parse_timestamp(timestamp, timestamp_extended) do
    import Bitwise
    (timestamp_extended <<< 24) + timestamp
  end
end

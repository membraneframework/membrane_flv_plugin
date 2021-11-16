defmodule Membrane.FLV.Serializer do
  @moduledoc false

  require Membrane.FLV.Packet
  alias Membrane.FLV.{Header, Packet}
  alias Membrane.AAC

  @type previous_tag_size() :: non_neg_integer()

  @spec serialize(Header.t() | Packet.t(), previous_tag_size()) :: {binary(), previous_tag_size()}
  def serialize(
        %Header{audio_present?: audio_present, video_present?: video_present},
        _last_item_size
      ) do
    <<
      "FLV",
      # verson
      0x01::8,
      # reserved,
      0::5,
      bool_to_flag(audio_present)::1,
      0::1,
      bool_to_flag(video_present)::1,
      # data offset
      9::32
    >>
    |> then(&{&1, 0})
  end

  def serialize(%Packet{} = packet, previous_tag_size) do
    <<previous_tag_size::32, flv_tag(packet)::binary>>
    |> then(&{&1, byte_size(&1) - 4})
  end

  defp flv_tag(%Packet{} = packet) do
    tag_header = tag_header(packet)
    data_size = byte_size(tag_header) + byte_size(packet.payload)

    <<
      0::3,
      tag_type(packet)::5,
      data_size::24,
      packet.timestamp::24,
      0::8,
      packet.stream_id::24,
      tag_header::binary,
      packet.payload::binary
    >>
  end

  defp bool_to_flag(true), do: 1
  defp bool_to_flag(false), do: 0

  defp tag_type(packet) when Packet.is_audio(packet), do: 8
  defp tag_type(packet) when Packet.is_video(packet), do: 9

  @aac_common_header <<10::4, 3::2, 1::1, 1::1>>
  defp tag_header(%Packet{type: :audio, codec: :AAC}), do: <<@aac_common_header, 1::8>>
  defp tag_header(%Packet{type: :audio_config, codec: :AAC}), do: <<@aac_common_header, 0::8>>

  defp tag_header(%Packet{codec: codec} = packet) when Packet.is_audio(packet) do
    codec = Membrane.FLV.index_to_sound_format(codec) |> inspect()
    raise ArgumentError, message: "Audio codec #{codec} is not supported"
  end

  defp tag_header(%Packet{type: :video, codec: :H264}) do
    <<
      # TODO: Actually use frame type
      1::4,
      # Hardcoded H264
      7::4,
      1::8,
      0::24-signed
    >>
  end

  defp tag_header(%Packet{type: :video_config, codec: :H264}) do
    <<
      # TODO: Actually use frame type
      1::4,
      # Hardcoded H264
      7::4,
      0::8,
      0::24
    >>
  end

  defp tag_header(%Packet{codec: codec} = packet) when Packet.is_video(packet) do
    codec = Membrane.FLV.index_to_video_codec(codec) |> inspect()
    raise ArgumentError, message: "Video codec #{codec} is not supported"
  end

  @spec acc_to_audio_specific_config(AAC.t()) :: binary()
  def acc_to_audio_specific_config(%AAC{} = caps) do
    aot = AAC.profile_to_aot_id(caps.profile)
    sr_index = AAC.sample_rate_to_sampling_frequency_id(caps.sample_rate)
    channel_configuration = AAC.channels_to_channel_config_id(caps.channels)

    frame_length_flag =
      case caps.samples_per_frame do
        960 -> 1
        1024 -> 0
      end

    <<
      aot::5,
      sr_index::4,
      channel_configuration::4,
      frame_length_flag::1,
      0::1,
      0::1
    >>
  end
end

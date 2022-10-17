defmodule Membrane.FLV.Serializer.Test do
  use ExUnit.Case

  test "keeps the correct timestamp above 4 hours" do
    packet = %Membrane.FLV.Packet{
      pts: :timer.hours(8),
      dts: :timer.hours(8),
      stream_id: 0,
      type: :audio,
      payload: <<0>>,
      codec: :AAC,
      codec_params: %{},
      frame_type: :keyframe
    }

    {serialized, _size} = Membrane.FLV.Serializer.serialize(packet, 0)
    {:ok, [parsed], ""} = Membrane.FLV.Parser.parse_body(serialized)

    assert packet.dts == parsed.dts
  end
end

defmodule Membrane.FLV.Muxer.Test do
  use ExUnit.Case

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  require Membrane.Pad

  alias Membrane.Pad
  alias Membrane.Testing.Pipeline

  @output "/tmp/output.flv"
  @reference "test/fixtures/reference.flv"

  setup do
    structure = [
      child(:muxer, Membrane.FLV.Muxer)
      |> child(:sink, %Membrane.File.Sink{location: @output}),
      child(:video_src, %Membrane.File.Source{location: "test/fixtures/input.h264"})
      |> child(:video_parser, %Membrane.H264.Parser{
        output_stream_structure: :avc1,
        generate_best_effort_timestamps: %{framerate: {30, 1}}
      })
      |> via_in(Pad.ref(:video, 0))
      |> get_child(:muxer),
      child(:audio_src, %Membrane.File.Source{location: "test/fixtures/input.aac"})
      |> child(:audio_parser, %Membrane.AAC.Parser{
        out_encapsulation: :none,
        output_config: :audio_specific_config
      })
      |> via_in(Pad.ref(:audio, 0))
      |> get_child(:muxer)
    ]

    pid = Pipeline.start_link_supervised!(spec: structure)

    %{pid: pid}
  end

  test "integration test", %{pid: pid} do
    assert_end_of_stream(pid, :sink, :input)

    result = File.read!(@output) |> prepare()
    reference = File.read!(@reference) |> prepare()

    assert result == reference
  end

  defp prepare(data) do
    {header, packets} = pop_header(data)
    packets = get_items(packets) |> MapSet.new()
    {header, packets}
  end

  defp pop_header(<<header::binary-size(9), rest::binary>>), do: {header, rest}

  defp get_items(<<_previous_tag_size::32, _head::8, data_size::24, _rest::binary>> = data) do
    packet_size = 11 + data_size
    <<_previous_tag_size::32, packet::binary-size(packet_size), rest::binary>> = data
    [packet | get_items(rest)]
  end

  defp get_items(<<_previous_tag_size::32>>), do: []
  defp get_items(<<>>), do: []
end

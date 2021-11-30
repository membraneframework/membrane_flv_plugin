defmodule Membrane.FLV.Muxer.Test do
  use ExUnit.Case

  import Membrane.Testing.Assertions
  import Membrane.ParentSpec

  require Membrane.Pad

  alias Membrane.Testing.Pipeline
  alias Membrane.Pad

  @output "/tmp/output.flv"
  @reference "test/fixtures/reference.flv"

  setup do
    {:ok, pid} =
      %Pipeline.Options{
        elements: [
          video_src: %Membrane.File.Source{location: "test/fixtures/input.h264"},
          audio_src: %Membrane.File.Source{location: "test/fixtures/input.aac"},
          audio_parser: %Membrane.AAC.Parser{
            in_encapsulation: :ADTS,
            out_encapsulation: :none
          },
          video_parser: %Membrane.H264.FFmpeg.Parser{
            attach_nalus?: true,
            alignment: :au,
            framerate: {30, 1}
          },
          video_payloader: Membrane.MP4.Payloader.H264,
          muxer: %Membrane.FLV.Muxer{video_present?: false},
          sink: %Membrane.File.Sink{location: @output}
        ],
        links: [
          link(:audio_src) |> to(:audio_parser) |> via_in(Pad.ref(:audio, 0)) |> to(:muxer),
          link(:video_src)
          |> to(:video_parser)
          |> to(:video_payloader)
          |> via_in(Pad.ref(:video, 0))
          |> to(:muxer),
          link(:muxer) |> to(:sink)
        ]
      }
      |> Pipeline.start_link()

    :ok = Pipeline.play(pid)
    on_exit(fn -> Pipeline.stop_and_terminate(pid, blocking?: true) end)
    %{pid: pid}
  end

  test "integration test", %{pid: pid} do
    assert_end_of_stream(pid, :sink, :input, 50_000)

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

  defp get_items(<<_previous_tag_size::32, head::8, data_size::24, _rest::binary>> = data) do
    packet_size = 11 + data_size
    <<_previous_tag_size::32, packet::binary-size(packet_size), rest::binary>> = data
    [packet | get_items(rest)]
  end

  defp get_items(<<_previous_tag_size::32>>), do: []
  defp get_items(<<>>), do: []
end

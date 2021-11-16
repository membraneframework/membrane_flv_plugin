defmodule TestPipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_opts) do
    spec = %ParentSpec{
      children: [
        audio_src: %Membrane.File.Source{location: "test/fixtures/input.aac"},
        video_src: %Membrane.File.Source{location: "test/fixtures/input.h264"},
        audio_parser: %Membrane.AAC.Parser{
          in_encapsulation: :ADTS,
          out_encapsulation: :none
        },
        video_parser: %Membrane.H264.FFmpeg.Parser{attach_nalus?: true, framerate: {24, 1}},
        video_payloader: Membrane.MP4.Payloader.H264,
        muxer: %Membrane.FLV.Muxer{video_present?: false},
        sink: %Membrane.File.Sink{location: "output.flv"}
      ],
      links: [
        link(:audio_src) |> to(:audio_parser) |> via_in(Pad.ref(:audio, 0)) |> to(:muxer),
        link(:video_src) |> to(:video_parser) |> to(:video_payloader) |> via_in(Pad.ref(:video, 0)) |> to(:muxer),
        link(:muxer) |> to(:sink)
      ]
    }
    {{:ok, spec: spec}, %{}}
  end
end

{:ok, pid} = TestPipeline.start_link(:nothing_to_see_here)
TestPipeline.play(pid)
Process.sleep(100_000)

Mix.install([
  :membrane_core,
  :membrane_hackney_plugin,
  :membrane_aac_plugin,
  :membrane_h264_ffmpeg_plugin,
  :membrane_mp4_plugin,
  :membrane_file_plugin,
  {:membrane_flv_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()}
])
defmodule Example do
  use Membrane.Pipeline

  @static_address "https://raw.githubusercontent.com/membraneframework/static/gh-pages"
  @video_input @static_address <> "/video_samples/test-video.h264"
  @audio_input @static_address <> "/samples/test-audio.aac"

  @output_file "output.flv"

  @impl true
  def handle_init(_opts) do
    spec = %ParentSpec{
      children: [
        video_src: %Membrane.Hackney.Source{
          location: @video_input,
          hackney_opts: [follow_redirect: true]
        },
        audio_src: %Membrane.Hackney.Source{
          location: @audio_input,
          hackney_opts: [follow_redirect: true]
        },
        audio_parser: %Membrane.AAC.Parser{
          in_encapsulation: :ADTS,
          out_encapsulation: :none
        },
        video_parser: %Membrane.H264.FFmpeg.Parser{attach_nalus?: true, alignment: :au, framerate: {30, 1}},
        video_payloader: Membrane.MP4.Payloader.H264,
        muxer: %Membrane.FLV.Muxer{video_present?: false},
        sink: %Membrane.File.Sink{location: @output_file}
      ],
      links: [
        link(:audio_src) |> to(:audio_parser) |> via_in(Pad.ref(:audio, 0)) |> to(:muxer),
        link(:video_src) |> to(:video_parser) |> to(:video_payloader) |> via_in(Pad.ref(:video, 0)) |> to(:muxer),
        link(:muxer) |> to(:sink)
      ]
    }
    {{:ok, spec: spec}, %{}}
  end

  # the rest of the Example module is only used for termination of the pipeline after processing finishes
  @impl true
  def handle_element_end_of_stream({:sink, _}, _ctx, state) do
    Pipeline.stop_and_terminate(self())
    {:ok, state}
  end

  @impl true
  def handle_element_end_of_stream(_, _context, state) do
    {:ok, state}
  end
end

# Initialize the pipeline and start it
{:ok, pid} = Example.start_link()
:ok = Membrane.Pipeline.play(pid)

monitor_ref = Process.monitor(pid)

# Wait for the pipeline to finish
receive do
  {:DOWN, ^monitor_ref, :process, _pid, _reason} ->
    :ok
end

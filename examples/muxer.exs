Mix.install([
  {:membrane_hackney_plugin, "~> 0.9.0"},
  {:membrane_aac_plugin, "~> 0.13.0"},
  {:membrane_h264_ffmpeg_plugin, "~> 0.25.0"},
  {:membrane_mp4_plugin, github: "membraneframework/membrane_mp4_plugin", branch: "core-0.11"},
  {:membrane_file_plugin, "~> 0.13.2"},
  {:membrane_flv_plugin, path: __DIR__ |> Path.join("..") |> Path.expand()}
])

defmodule Example do
  use Membrane.Pipeline

  @static_address "https://raw.githubusercontent.com/membraneframework/static/gh-pages"
  @video_input @static_address <> "/samples/ffmpeg-testsrc.h264"
  @audio_input @static_address <> "/samples/test-audio.aac"

  @output_file "output.flv"

  @impl true
  def handle_init(_ctx, _opts) do
    structure = [
      child(:muxer, Membrane.FLV.Muxer)
      |> child(:sink, %Membrane.File.Sink{location: @output_file}),
      # setup input audio stream
      child({:source, :audio}, %Membrane.Hackney.Source{
        location: @audio_input,
        hackney_opts: [follow_redirect: true]
      })
      |> child({:parser, :audio}, %Membrane.AAC.Parser{
        in_encapsulation: :ADTS,
        out_encapsulation: :none
      })
      |> via_in(Pad.ref(:audio, 0))
      |> get_child(:muxer),
      # setup input video stream
      child({:source, :video}, %Membrane.Hackney.Source{
        location: @video_input,
        hackney_opts: [follow_redirect: true]
      })
      |> child({:parser, :video}, %Membrane.H264.FFmpeg.Parser{
        attach_nalus?: true,
        alignment: :au,
        framerate: {30, 1}
      })
      |> child({:payloader, :video}, Membrane.MP4.Payloader.H264)
      |> via_in(Pad.ref(:video, 0))
      |> get_child(:muxer)
    ]

    {[spec: structure, playback: :playing], %{}}
  end

  # the rest of the Example module is only used for termination of the pipeline after processing finishes
  @impl true
  def handle_element_end_of_stream(:sink, _pad, _ctx, state) do
    {[terminate: :shutdown], state}
  end

  @impl true
  def handle_element_end_of_stream(_child, _pad, _ctx, state) do
    {[], state}
  end
end

# Initialize the pipeline and start it
{:ok, _supervisor_pid, pipeline_pid} = Example.start_link()

monitor_ref = Process.monitor(pipeline_pid)

# Wait for the pipeline to finish
receive do
  {:DOWN, ^monitor_ref, :process, _pipeline_pid, _reason} ->
    :ok
end

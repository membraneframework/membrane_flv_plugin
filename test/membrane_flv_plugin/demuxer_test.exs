defmodule Membrane.FLV.Demuxer.Test do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions

  alias Membrane.Testing.Pipeline

  defmodule Support.Pipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      structure = [
        child(:src, %Membrane.File.Source{
          location: opts.input_flv_path
        })
        |> child(:demuxer, Membrane.FLV.Demuxer)
        # pre-link only audio to cover both pre-link and dynamic linking cases
        |> via_out(Pad.ref(:audio, 0))
        |> child({:parser, :audio}, %Membrane.AAC.Parser{out_encapsulation: :ADTS})
        |> child({:sink, :audio}, %Membrane.File.Sink{location: opts.output_audio_path})
      ]

      {[spec: structure], opts}
    end

    @impl true
    def handle_child_notification(
          {:new_stream, Pad.ref(:video, 0), :H264},
          :demuxer,
          _ctx,
          state
        ) do
      structure = [
        get_child(:demuxer)
        |> via_out(Pad.ref(:video, 0))
        |> child({:parser, :video}, Membrane.H264.Parser)
        |> child({:sink, :video}, %Membrane.File.Sink{location: state.output_video_path})
      ]

      {[spec: structure], state}
    end
  end

  setup ctx do
    out_paths =
      %{
        output_audio_path: Path.join(ctx.tmp_dir, "audio.aac"),
        output_video_path: Path.join(ctx.tmp_dir, "video.h264")
      }

    pid =
      Pipeline.start_link_supervised!(
        module: Support.Pipeline,
        custom_args: Map.put(out_paths, :input_flv_path, "test/fixtures/reference.flv")
      )

    Map.put(out_paths, :pid, pid)
  end

  @tag :tmp_dir
  test "streams are detected", %{pid: pid} = ctx do
    assert_pipeline_notified(pid, :demuxer, {:new_stream, _pad, :H264})
    assert_end_of_stream(pid, {:sink, :video}, :input)
    assert_end_of_stream(pid, {:sink, :audio}, :input)

    assert {:ok, audio} = File.read(ctx.output_audio_path)
    assert {:ok, video} = File.read(ctx.output_video_path)

    assert byte_size(audio) == 96_303
    assert byte_size(video) == 144_918
  end
end

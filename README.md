# Membrane FLV Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_flv_plugin.svg)](https://hex.pm/packages/membrane_flv_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_flv_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_flv_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_flv_plugin)

This package contains muxer and demuxer for FLV format. Currently it only supports AAC audio and H264 video

It is part of [Membrane Multimedia Framework](https://membraneframework.org).

## Installation

The package can be installed by adding `membrane_flv_plugin` to your list of dependencies in `mix.exs`.

```elixir
def deps do
  [
	{:membrane_flv_plugin, "~> 0.3.0"}
  ]
end
```

## Usage
For usage examples, checkout [examples](https://github.com/membraneframework/membrane_flv_plugin/tree/master/examples) folder

Available examples:
- [examples/demuxer.exs](https://github.com/membraneframework/membrane_flv_plugin/tree/master/examples/demuxer.exs) - a demonstaration of demuxing an FLV file. To run it, simply run `elixir examples/demuxer.exs`. It should generate `audio.aac` and `video.aac` extracted from the container. This examples relies on an FLV file that is part of the repository. If you cloned the repository - it should work without any modifications.
- [examples/muxer.exs](https://github.com/membraneframework/membrane_flv_plugin/tree/master/examples/muxer.exs) - demonstration of muxing AAC and H264 to an FLV file. To run the example, run `elixir examples/muxer.exs`. It should generate `output.flv` file containing the contents of both of the source files.

## Copyright and License

Copyright 2022, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_flv_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_flv_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)

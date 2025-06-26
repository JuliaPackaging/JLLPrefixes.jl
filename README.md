# JLLPrefixes

Collect, symlink and copy around prefixes of JLL packages!  This package makes it easy to use prefixes of JLL packages outside of Julia, either by symlinking or copying them to a stable prefix.

Example:

```julia
using JLLPrefixes

# Download all of FFMPEG_jll, then copy all the files into the ~/local/ffmpeg_prefix` folder
prefix = expanduser("~/local/ffmpeg_prefix")
artifact_paths = collect_artifact_paths(["FFMPEG_jll"])
deploy_artifact_paths(prefix, artifact_paths)
run(`$(joinpath(prefix, "bin", "ffmpeg")) -version`)
```

The files are now available to be used outside of Julia!  No more `LD_LIBRARY_PATH` shenanigans!  Note that some tools (such as `git`) may still need some help finding their data files, and so you may still need to define _some_ environment variables.

## Using versions from the current manifest

If you want to use the exact versions from your current environment's manifest instead of resolving new versions, you can use the `from_current_manifest` option:

```julia
using JLLPrefixes

# Use versions from the current active manifest
prefix = expanduser("~/local/my_prefix")
artifact_paths = collect_artifact_paths(["FFMPEG_jll"]; from_current_manifest=true)
deploy_artifact_paths(prefix, artifact_paths)
```

This is useful for reproducing environments from a Manifest.toml - simply activate that environment first, then use `from_current_manifest=true` to collect artifacts using the exact versions specified in the manifest.

## Deployment strategies

By default, `JLLPrefixes` will attempt to use `hardlink()` to hit the sweet spot of performance (hardlinking is faster than copying) and compatibility (executables with RPATHs and other relative paths embedded within them don't play well with symlinks).
If you are unable to use hardlinks (e.g. your source and destination are located on different filesystems/devices) it will silently fall back to using `copy()`.
If you require high performance and don't care about compatibility with executables with embedded relative paths, you can manually request `deploy_artifact_paths()` to use `symlink()` by passing `:symlink` as the `strategy` keyword argument.

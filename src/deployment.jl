function symlink_tree(dest::AbstractString, src::AbstractString; verbose::Bool=true)
    for (root, dirs, files) in walkdir(src)
        # Create all directories
        for d in dirs
            d_path = joinpath(root, d)
            dest_dir = joinpath(dest, relpath(root, src), d)
            if ispath(dest_dir) && !isdir(realpath(dest_dir))
                # We can't create a directory if the destination exists and
                # is not a directory or a symlink to a directory.
                error("Directory $(d) from artifact $(basename(src)) already exists on disk and is not a directory")
            end
            mkpath(dest_dir)
        end

        # Symlink all files
        for f in files
            src_file = joinpath(root, f)
            dest_file = joinpath(dest, relpath(root, src), f)
            if isfile(dest_file)
                # Ugh, destination file already exists.  If source and destination files
                # have the same size and SHA256 hash, just move on, otherwise issue a
                # warning.
                if filesize(src_file) == filesize(dest_file)
                    src_file_hash = open(io -> bytes2hex(sha256(io)), src_file, "r")
                    dest_file_hash = open(io -> bytes2hex(sha256(io)), dest_file, "r")
                    if src_file_hash == dest_file_hash
                        continue
                    end
                end

                # Find source artifact that this pre-existent destination file belongs to
                if verbose
                    dest_artifact_source = realpath(dest_file)
                    while occursin("artifacts", dest_artifact_source) && basename(dirname(dest_artifact_source)) != "artifacts"
                        dest_artifact_source = dirname(dest_artifact_source)
                    end
                    @warn("Symlink $(f) from artifact $(basename(src)) already exists in artifact $(basename(dest_artifact_source))")
                end
            else
                # If it's already a symlink, copy over the exact symlink target
                if islink(src_file)
                    symlink(readlink(src_file), dest_file)
                else
                    # Otherwise, point it at the proper location
                    symlink(relpath(src_file, dirname(dest_file)), dest_file)
                end
            end
        end
    end
end

function undeploy_tree(dest::AbstractString, src::AbstractString)
    for (root, dirs, files) in walkdir(src)
        # Delete all files in `dest` that match `src`
        for f in files
            dest_file = joinpath(dest, relpath(root, src), f)
            rm(dest_file; force=true)
        end
    end
end

function copy_tree(dest::AbstractString, src::AbstractString; verbose::Bool=true)
    for (root, dirs, files) in walkdir(src)
        # Create all directories
        for d in dirs
            d_path = joinpath(root, d)
            dest_dir = joinpath(dest, relpath(root, src), d)
            if ispath(dest_dir) && !isdir(realpath(dest_dir))
                # We can't create a directory if the destination exists and
                # is not a directory or a symlink to a directory.
                error("Directory $(d) from artifact $(basename(src)) already exists on disk and is not a directory")
            end
            mkpath(dest_dir)
        end

        # Copy all files
        for f in files
            src_file = joinpath(root, f)
            dest_file = joinpath(dest, relpath(root, src), f)
            if isfile(dest_file)
                # Ugh, destination file already exists.  If source and destination files
                # have the same size and SHA256 hash, just move on, otherwise issue a
                # warning.
                if filesize(src_file) == filesize(dest_file)
                    src_file_hash = open(io -> bytes2hex(sha256(io)), src_file, "r")
                    dest_file_hash = open(io -> bytes2hex(sha256(io)), dest_file, "r")
                    if src_file_hash == dest_file_hash
                        continue
                    end
                end

                # Find source artifact that this pre-existent destination file belongs to
                if verbose
                    @warn("File $(f) from $(dirname(src_file)) already exists in $(dest)")
                end
            else
                # If it's already a symlink, copy over the exact symlink target
                cp(src_file, dest_file)
            end
        end
    end
end


function hardlink_tree(dest::AbstractString, src::AbstractString; verbose::Bool=true)
    for (root, dirs, files) in walkdir(src)
        # Create all directories
        for d in dirs
            d_path = joinpath(root, d)
            dest_dir = joinpath(dest, relpath(root, src), d)
            if ispath(dest_dir) && !isdir(realpath(dest_dir))
                # We can't create a directory if the destination exists and
                # is not a directory or a symlink to a directory.
                error("Directory $(d) from artifact $(basename(src)) already exists on disk and is not a directory")
            end
            mkpath(dest_dir)
        end

        # Hardlink all files
        for f in files
            src_file = joinpath(root, f)
            dest_file = joinpath(dest, relpath(root, src), f)
            if isfile(dest_file)
                # Ugh, destination file already exists.  If source and destination files
                # have the same size and SHA256 hash, just move on, otherwise issue a
                # warning.
                if filesize(src_file) == filesize(dest_file)
                    src_file_hash = open(io -> bytes2hex(sha256(io)), src_file, "r")
                    dest_file_hash = open(io -> bytes2hex(sha256(io)), dest_file, "r")
                    if src_file_hash == dest_file_hash
                        continue
                    end
                end

                # Find source artifact that this pre-existent destination file belongs to
                if verbose
                    @warn("File $(f) from $(dirname(src_file)) already exists in $(dest)")
                end
            else
                # If it's already a symlink, copy over the exact symlink target
                hardlink(src_file, dest_file)
            end
        end
    end
end


# Figure out the preferred method for installing artifacts.
# In general, we like to hardlink.  But we can't do that if we're trying to
# cross device boundaries, so we just try it.  :)
"""
    probe_strategy(dest, artifact_paths)

Given a destination and a set of source paths the artifacts are coming from,
automatically determine whether we can use the `:hardlink` strategy, which may
not be available to us if we are crossing a drive device boundary.  If we
cannot use `:hardlink`, we default to `:copy`, which is the safest, but slowest
strategy.
"""
function probe_strategy(dest::String, artifact_paths::Vector{String})
    probe_target = joinpath(dest, "jllprefix.probe")
    rm(probe_target; force=true)
    mkpath(dest)

    # Assume that if arifacts are within the same depot, they're on the same filesystem.
    depot_paths = Dict{String,String}()
    for path in artifact_paths
        depot = dirname(dirname(path))
        if !haskey(depot_paths, depot)
            depot_paths[depot] = path
        end
    end

    try
        for src in values(depot_paths)
            for (root, dirs, files) in walkdir(src)
                # Just try to hardlink one file to the destination
                if !isempty(files)
                    hardlink(joinpath(root, first(files)), probe_target)
                    rm(probe_target; force=true)
                    break
                end
            end
        end
    catch e
        # If we got an error from trying to hardlink something, fail out.
        if isa(e, Base.IOError) && e.code ∈ (-Base.Libc.EXDEV, Base.UV_EXDEV)
            return :copy
        end

        # Something else went wrong that we weren't expecting
        rethrow(e)
    finally
        # Just in case something goes wrong between the `hardlink()` and the
        # `rm()`; we really want no possibility of littering.
        rm(probe_target; force=true)
    end

    # We successfully hardlinked from every source artifact directory to our
    # destination directory!  Huzzah!  Enable hardlinks.  :)
    return :hardlink
end

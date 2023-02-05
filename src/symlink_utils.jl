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

function unsymlink_tree(dest::AbstractString, src::AbstractString)
    for (root, dirs, files) in walkdir(src)
        # Unsymlink all symlinked directories, non-symlink directories will be culled in audit.
        for d in dirs
            dest_dir = joinpath(dest, relpath(root, src), d)
            if islink(dest_dir)
                rm(dest_dir)
            end
        end

        # Unsymlink all symlinked files
        for f in files
            dest_file = joinpath(dest, relpath(root, src), f)
            if islink(dest_file)
                rm(dest_file)
            end
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

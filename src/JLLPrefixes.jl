module JLLPrefixes
using Pkg, Pkg.Artifacts, Base.BinaryPlatforms

export collect_artifact_metas, collect_artifact_paths, deploy_artifact_paths, undeploy_artifact_paths

# Bring in helpers for git repositories
include("git_utils.jl")

# Bring in helpers to deal with JLL packages
include("pkg_utils.jl")

# Bring in helpers to deal with hardlinking, symlinking, etc...
include("deployment.jl")

function __init__()
    update_pkg_historical_stdlibs()
end

"""
    collect_artifact_metas(dependencies::Vector;
                           platform = HostPlatform(),
                           verbose = false)

Collect (recursive) JLL dependency artifact metadata for the given `platform`.  Returns
a dictionary mapping each (recursive) dependency to its set of artifact metas, which
can then be transformed or flattened and given to other tools, such as
`symlink_artifact_paths()` or `copy_artifact_paths()`.

Because the dependencies can be specified as a `PkgSpec`, it is possible to request
particular versions of a package just as you would with `Pkg.add()`.

The `platform` keyword argument allows for collecting artifacts for a foreign platform,
as well as a different Julia version.  This is especially useful for packages that are
stdlibs, and thus locked to a single version based on the Julia version.
"""
function collect_artifact_metas(dependencies::Vector{PkgSpec};
                                platform::AbstractPlatform = HostPlatform(),
                                project_dir::AbstractString = mktempdir(),
                                pkg_depot::AbstractString = Pkg.depots1(),
                                verbose::Bool = false)
    # We occasionally generate "illegal" package specs, where we provide both version and tree hash.
    # we trust the treehash over the version, so drop the version for any that exists here:
    function filter_redundant_version(p::PkgSpec)
        if p.version !== nothing && p.tree_hash !== nothing
            return Pkg.Types.PackageSpec(;name=p.name, tree_hash=p.tree_hash, repo=p.repo, url=p.url)
        end
        return p
    end
    dependencies = filter_redundant_version.(dependencies)
    dependencies_names = [d.name for d in dependencies]

    # Get julia version specificity, if it exists, from the `Platform` object
    julia_version = nothing
    if haskey(platform, "julia_version")
        julia_version = VersionNumber(platform["julia_version"])
    end

    # Until https://github.com/JuliaLang/julia/pull/48749 is resolved...
    if !haskey(platform, "sanitize")
        platform["sanitize"] = "false"
    end

    # This is what we will eventually return
    artifact_metas = Dict{PkgSpec, Vector{Dict}}()

    # We're going to create a project and install all dependent packages within
    # it, then create symlinks from those installed products to our build prefix
    deps_project = joinpath(project_dir, "Project.toml")
    with_no_pkg_handrails() do; with_depot_path(pkg_depot) do; Pkg.activate(deps_project) do
        pkg_io = verbose ? stdout : devnull

        # Update registry first, in case the jll packages we're looking for have just been registered/updated
        update_registry(pkg_io)

        # Create `Context` object _after_ updating registries, as if we're in
        # a brand-new depot, we need to install them first!
        ctx = Pkg.Types.Context(;julia_version)

        # Add all dependencies to our project
        Pkg.add(ctx, dependencies; platform, io=pkg_io)

        # Ony Julia v1.6, `Pkg.add()` doesn't mutate `dependencies`, so we can't use the `UUID`
        # that was found during resolution there.  Instead, we'll make use of `ctx.env` to figure
        # out the UUIDs of all our packages.
        dependency_uuids = Set([uuid for (uuid, pkg) in ctx.env.manifest if pkg.name ∈ dependencies_names])

        # Some JLLs are also standard libraries that may be present in the manifest because
        # they were pulled by other stdlibs (e.g. through dependence on `Pkg`), not beacuse
        # they were actually required for this package. Filter them out if they're present
        # in the manifest but aren't direct dependencies or dependencies of other JLLS.
        installed_jll_uuids = collect_jll_uuids(ctx.env.manifest, dependency_uuids)
        installed_jlls = [
            PkgSpec(;
                name=pkg.name,
                uuid,
                tree_hash=pkg.tree_hash,
            ) for (uuid, pkg) in ctx.env.manifest if uuid ∈ installed_jll_uuids
        ]

        # Check for stdlibs lurking in the installed JLLs
        stdlib_pkgspecs = PkgSpec[]
        for dep in installed_jlls
            # If the `tree_hash` is `nothing`, then this JLL was treated as an stdlib
            if dep.tree_hash === nothing
                # Figure out what version this stdlib _should_ be at for this version
                dep.version = stdlib_version(dep.uuid, julia_version)

                # Interrogate the registry to determine the correct treehash
                Pkg.Operations.load_tree_hash!(ctx.registries, dep, nothing)

                # We'll still use `Pkg.add()` to install the version we want, even though
                # we've used the above two lines to figure out the treehash, so construct
                # an addable spec that will get the correct bits down on disk.
                push!(stdlib_pkgspecs, get_addable_spec(dep.name, dep.version; verbose))
            end
        end

        # Re-install stdlib dependencies, but this time with `julia_version = nothing`
        if !isempty(stdlib_pkgspecs)
            Pkg.add(ctx, stdlib_pkgspecs; io=pkg_io, julia_version=nothing)
        end

        # Load their Artifacts.toml files
        for dep in installed_jlls
            dep_path = Pkg.Operations.find_installed(dep.name, dep.uuid, dep.tree_hash)

            # Skip dependencies that didn't get installed, but warn as this should never happen
            if dep_path === nothing
                @warn("Dependency $(dep.name) not installed, despite our best efforts!")
                continue
            end

            # Load the Artifacts.toml file
            artifacts_toml = joinpath(dep_path, "Artifacts.toml")
            if !isfile(artifacts_toml)
                # Try `StdlibArtifacts.toml` instead
                artifacts_toml = joinpath(dep_path, "StdlibArtifacts.toml")
                if !isfile(artifacts_toml)
                    @warn("Dependency $(dep.name) does not have an (Stdlib)Artifacts.toml in $(dep_path)!")
                    continue
                end
            end

            # If the artifact is available for the given platform, make sure it
            # is also installed.  It may not be the case for lazy artifacts.
            meta = artifact_meta(dep.name[1:end-4], artifacts_toml; platform)
            if meta === nothing
                # This only gets printed if we're verbose, as this can be kind of common
                if verbose
                    @warn("Dependency $(dep.name) does not have a mapping for artifact $(dep.name[1:end-4]) for platform $(triplet(platform))")
                end
                continue
            end
            meta = copy(meta)

            # NOTE: We are here assuming that each dependency should download only a single
            # artifact with a specific name (e.g. `Zlib_jll` should download the `Zlib`
            # artifact).  This is currently how JLLs work, but it may not always be the case!
            # We need to come up with some way of allowing the user to specify _which_ artifacts
            # they want downloaded!
            ensure_artifact_installed(dep.name[1:end-4], meta, artifacts_toml)

            # Save the artifact path here and now
            meta["path"] = Pkg.Artifacts.artifact_path(Base.SHA1(meta["git-tree-sha1"]))
            
            # Keep track of our dep paths for later symlinking
            if !haskey(artifact_metas, dep)
                artifact_metas[dep] = Dict[]
            end
            push!(artifact_metas[dep], meta)
        end
    end; end; end

    return artifact_metas
end
function collect_artifact_metas(pkg_names::Vector{<:AbstractString}; kwargs...)
    return collect_artifact_metas(
        [PackageSpec(; name) for name in pkg_names];
        kwargs...
    )
end

"""
    collect_artifact_paths(dependencies::Vector;
                           platform = HostPlatform(),
                           verbose = false)

A convenience wrapper around `collect_artifact_metas()` that will peel the
`meta` objects and return a vector of paths for each package returned.
"""
function collect_artifact_paths(args...; kwargs...)
    meta_mappings = collect_artifact_metas(args...; kwargs...)
    return Dict{PkgSpec,Vector{String}}(
        pkg => [m["path"] for m in metas] for (pkg, metas) in meta_mappings
    )
end

# Helper function for throwing away the `PkgSpec` information
function flatten_artifact_paths(d::Dict{PkgSpec, Vector{String}})
    return vcat(values(d)...)
end



"""
    deploy_artifact_paths(dest::AbstractString, artifact_paths;
                          strategy::Symbol = :auto)

Deploy the given artifacts into the given destination location, using the
specified deployment strategy.  There are three strategies available to use:
`:symlink`, `:hardlink` and `:copy`.  By defauly, `deploy_artifact_paths()`
will probe to see if `:hardlink` is allowed, and if so use it.  Otherwise, it
will fall back to `:copy`, as that is the safest for dealing with executables
that expect to be able to use `RPATH` to find dependent libraries at a relative
path to themselves.  You can set `:symlink` to force usage of symlinks if you
are certain that `:hardlink` will not work, and you do not need the files to
reside physically next to eachother.
"""
function deploy_artifact_paths(dest::AbstractString, artifact_paths::Vector{String};
                               strategy::Symbol = :auto, verbose::Bool = true)
    # The special symbol `:auto` will try `:hardlink`, and if that fails
    # it will use `:copy`.  The only way to get `:symlink` is to ask for it.
    if strategy == :auto
        strategy = probe_strategy(string(dest), artifact_paths)
    end
    if strategy ∉ (:symlink, :hardlink, :copy)
        throw(ArgumentError("Invalid strategy type :$(strategy)!"))
    end

    # Dynamic dispatch?  What's that?
    for artifact_path in artifact_paths
        if strategy == :symlink
            symlink_tree(dest, artifact_path; verbose)
        elseif strategy == :hardlink
            hardlink_tree(dest, artifact_path; verbose)
        elseif strategy == :copy
            copy_tree(dest, artifact_path; verbose)
        end
    end
end

function deploy_artifact_paths(dest::AbstractString, artifact_paths::Dict{PkgSpec, Vector{String}}; kwargs...)
    return deploy_artifact_paths(dest, flatten_artifact_paths(artifact_paths); kwargs...)
end

"""
    undeploy_artifact_paths(dest, artifact_paths)

To cleanup a destination prefix, use `undeploy_artifact_paths()` to delete all
files that exist within the source `artifact_paths` and the `dest`.
"""
function undeploy_artifact_paths(dest::AbstractString, artifact_paths::Vector{String})
    for artifact_path in artifact_paths
        undeploy_tree(dest, artifact_path)
    end
end

function undeploy_artifact_paths(dest::AbstractString, artifact_paths::Dict{PkgSpec, Vector{String}})
    return undeploy_artifact_paths(dest, flatten_artifact_paths(artifact_paths))
end

end # module JLLPrefixes

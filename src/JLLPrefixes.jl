module JLLPrefixes
using Pkg, Pkg.Artifacts, Base.BinaryPlatforms

export collect_artifact_paths, symlink_artifact_paths, unsymlink_artifact_paths, copy_artifact_paths

# Bring in helpers for git repositories
include("libgit2_utils.jl")

# Bring in helpers to deal with JLL packages
include("pkg_utils.jl")

# Bring in helpers to deal with symlink nests
include("symlink_utils.jl")

# Only update the registry once per session, by default
const _registry_updated = Ref(false)

"""
    collect_artifact_paths(dependencies::Vector;
                           platform = HostPlatform(),
                           verbose = false)

Collect all (recursive) JLL dependency artifact paths for the given `platform`.  Returns
a dictionary mapping each (recursive) dependency to its set of artifact paths, which
can then be flattened and given to other tools, such as `symlink_artifact_paths()` or
`copy_artifact_paths()`.

Because the dependencies can be specified as a `PkgSpec`, it is possible to request
particular versions of a package just as you would with `Pkg.add()`.

The `platform` keyword argument allows for collecting artifacts for a foreign platform,
as well as a different Julia version.  This is especially useful for packages that are
stdlibs, and thus locked to a single version based on the Julia version.
"""
function collect_artifact_paths(dependencies::Vector{PkgSpec};
                                platform::AbstractPlatform = HostPlatform(),
                                project_dir::AbstractString = mktempdir(),
                                update_registry::Bool = _registry_updated[],
                                verbose::Bool = false)
    # We occasionally generate "illegal" package specs, where we provide both version and tree hash.
    # we trust the treehash over the version, so drop the version for any that exists here:
    function filter_redundant_version(p::PkgSpec)
        if p.version !== nothing && p.tree_hash !== nothing
            return Pkg.Types.PackageSpec(;name=p.name, tree_hash=p.tree_hash, repo=p.repo)
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

    # This is what we will eventually return
    artifact_paths = Dict{PkgSpec, Vector{String}}()

    # We're going to create a project and install all dependent packages within
    # it, then create symlinks from those installed products to our build prefix
    deps_project = joinpath(project_dir, "Project.toml")
    Pkg.activate(deps_project) do
        ctx = Pkg.Types.Context(;julia_version)
        pkg_io = verbose ? stdout : devnull

        # Update registry first, in case the jll packages we're looking for have just been registered/updated
        if update_registry
            Pkg.Registry.update(
                [Pkg.RegistrySpec(uuid = "23338594-aafe-5451-b93e-139f81909106")];
                io=pkg_io,
            )
            _registry_updated[] = true
        end

        # Add all dependencies to our project
        Pkg.add(ctx, dependencies; platform=platform, io=pkg_io)

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
            meta = artifact_meta(dep.name[1:end-4], artifacts_toml; platform=platform)
            if meta === nothing
                # This only gets printed if we're verbose, as this can be kind of common
                if verbose
                    @warn("Dependency $(dep.name) does not have a mapping for artifact $(dep.name[1:end-4]) for platform $(triplet(platform))")
                end
                continue
            end

            # NOTE: We are here assuming that each dependency should download only a single
            # artifact with a specific name (e.g. `Zlib_jll` should download the `Zlib`
            # artifact).  This is currently how JLLs work, but it may not always be the case!
            # We need to come up with some way of allowing the user to specify _which_ artifacts
            # they want downloaded!
            ensure_artifact_installed(dep.name[1:end-4], meta, artifacts_toml; platform=platform)

            # Copy the artifact from the global installation location into this build-specific artifacts collection
            src_path = Pkg.Artifacts.artifact_path(Base.SHA1(meta["git-tree-sha1"]))
            
            # Keep track of our dep paths for later symlinking
            if !haskey(artifact_paths, dep)
                artifact_paths[dep] = String[]
            end
            push!(artifact_paths[dep], src_path)
        end
    end

    return artifact_paths
end
function collect_artifact_paths(pkg_names::Vector{<:AbstractString}; kwargs...)
    return collect_artifact_paths(
        [PackageSpec(; name) for name in pkg_names];
        kwargs...
    )
end

# Helper function for throwing away the `PkgSpec` information
function flatten_artifact_paths(d::Dict{PkgSpec, Vector{String}})
    return vcat(values(d)...)
end


"""
    symlink_artifact_paths(dest::String, artifact_paths)

Symlinks all files from the given `artifact_paths` to the given `dest`.
Provides a merged symlink nest for smashing multiple JLLs together into a single
prefix, as a cheaper alternative to `copy_artifact_paths`.
"""
function symlink_artifact_paths(dest::AbstractString, artifact_paths::Vector{String}; verbose::Bool = true)
    for artifact_path in artifact_paths
        symlink_tree(dest, artifact_path; verbose)
    end
end
function symlink_artifact_paths(dest::AbstractString, artifact_paths::Dict{PkgSpec, Vector{String}}; kwargs...)
    return symlink_artifact_paths(dest, flatten_artifact_paths(artifact_paths); kwargs...)
end

"""
    unsymlink_artifact_paths(dest::String, artifact_paths)

Removes all symlinks in `dest` that originate from `artifact_paths`.  Useful if
there is a mixture of symlinked artifacts and other files, and you want to remove
all symlinks from the artifact paths.
"""
function unsymlink_artifact_paths(dest::AbstractString, artifact_paths::Vector{String})
    for artifact_path in artifact_paths
        unsymlink_tree(dest, artifact_path)
    end
end
function unsymlink_artifact_paths(dest::AbstractString, artifact_paths::Dict{PkgSpec, Vector{String}})
    return unsymlink_artifact_paths(dest, flatten_artifact_paths(artifact_paths))
end


"""
    copy_artifact_paths(dest::String, artifact_paths)
"""
function copy_artifact_paths(dest::AbstractString, artifact_paths::Vector{String})
    for artifact_path in artifact_paths
        copy_tree(dest, artifact_path)
    end
end
function copy_artifact_paths(dest::AbstractString, artifact_paths::Dict{PkgSpec, Vector{String}})
    return copy_artifact_paths(dest, flatten_artifact_paths(artifact_paths))
end

end # module JLLPrefixes

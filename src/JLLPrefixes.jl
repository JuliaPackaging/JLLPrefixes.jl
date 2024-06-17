module JLLPrefixes
using Pkg, Pkg.Artifacts, Base.BinaryPlatforms

export collect_artifact_metas, collect_artifact_paths, deploy_artifact_paths, undeploy_artifact_paths

# Bring in helpers for git repositories
include("git_utils.jl")

# Bring in helpers to deal with JLL packages
include("pkg_utils.jl")

# Bring in helpers to deal with hardlinking, symlinking, etc...
include("deployment.jl")

global _git_clones_dir::Ref{String} = Ref{String}()
function __init__()
    update_pkg_historical_stdlibs()

    # Read in our `clones_dir` preference once
    set_git_clones_dir!(@load_preference("clones_dir", @get_scratch!("git_clones")))
end

# provide programmatic way of setting it for this session
function set_git_clones_dir!(clones_dir::String)
    global _git_clones_dir[] = clones_dir
end
get_git_clones_dir() = _git_clones_dir[]

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
    # Get julia version specificity, if it exists, from the `Platform` object
    julia_version = nothing
    if haskey(platform, "julia_version")
        julia_version = VersionNumber(platform["julia_version"])
    end

    # Julia versions without https://github.com/JuliaLang/julia/pull/49502 need a workaround...
    if VERSION < v"1.10.0" && !haskey(platform, "sanitize")
        platform = deepcopy(platform)
        platform["sanitize"] = "false"
    end

    # This is what we will eventually return
    artifact_metas = Dict{PkgSpec, Dict}()

    # We're going to create a project and install all dependent packages within
    # it, then create symlinks from those installed products to our build prefix
    deps_project = joinpath(project_dir, "Project.toml")
    with_no_pkg_handrails() do; with_no_auto_precompilation() do; with_depot_path(pkg_depot) do; Pkg.activate(deps_project) do
        pkg_io = verbose ? stdout : devnull

        # Update registry first, in case the jll packages we're looking for have just been registered/updated
        update_registry(pkg_io)

        # Create `Context` object _after_ updating registries, as if we're in
        # a brand-new depot, we need to install them first!
        ctx = Pkg.Types.Context(;julia_version)

        # We need UUIDs so that we can ask things like `is_stdlib()` later
        Pkg.Types.stdlib_resolve!(dependencies)

        function find_manifest_entry(dep)
            if haskey(ctx.env.manifest.deps, dep.uuid)
                return ctx.env.manifest.deps[dep.uuid]
            end
            for (uuid, entry) in ctx.env.manifest.deps
                if entry.name == dep.name
                    return entry
                end
            end
            return nothing
        end

        # Normalize `version`, `treehash`, `repo`, etc...
        # If a `repo` is given we're always happy, but make sure to blank out `version` as it's illegal to specify both.
        # If `repo` is not given, we need to check to see if `dep` is a standard library, as if it is, we actually
        # need to have `repo` specified if `version` or `treehash` are set.  This is because of `Pkg` internals that
        # ignore `treehash` and `version` but not `repo` for stdlibs.
        dependencies = map(dependencies) do dep
            pkg_entry = find_manifest_entry(dep)
            # If our manifest already has a mapping for this dependency, just use that.
            if pkg_entry !== nothing
                dep = PackageSpec(;
                    name = pkg_entry.name,
                    uuid = pkg_entry.uuid,
                    version = pkg_entry.version,
                    tree_hash = pkg_entry.tree_hash,
                    path = pkg_entry.path,
                    repo = pkg_entry.repo,
                )
            elseif dep.uuid !== nothing && Pkg.Types.is_stdlib(dep.uuid) && dep.version != Pkg.Types.VersionSpec()
                dep = get_addable_spec(dep.name, dep.version; ctx)
            end

            if dep.repo.source !== nothing || dep.repo.rev !== nothing
                # It's illegal to specify both `version` and `repo`
                dep.version = Pkg.Types.VersionSpec()
            end
            return dep
        end
        dependencies_names = [d.name for d in dependencies]

        # Add all dependencies to our project.
        Pkg.add(ctx, dependencies; platform, io=pkg_io, julia_version=julia_version)

        # On Julia v1.6, `Pkg.add()` doesn't mutate `dependencies`, so we can't use the `UUID`
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
                path=pkg.path,
            ) for (uuid, pkg) in ctx.env.manifest if uuid ∈ installed_jll_uuids
        ]

        # Check for stdlibs lurking in the installed JLLs
        stdlib_pkgspecs = PkgSpec[]
        for dep in installed_jlls
            # Check for dependencies that didn't actually get installed (typically stdlibs)
            if dep.tree_hash === nothing && dep.path === nothing
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
            if dep.path !== nothing
                dep_path = dep.path
            else
                dep_path = Pkg.Operations.find_installed(dep.name, dep.uuid, dep.tree_hash)
            end
            dep_dep_uuids = [uuid for (_, uuid) in ctx.env.manifest[dep.uuid].deps if any(jll.uuid == uuid for jll in installed_jlls)]

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
                # Save an empty mapping in `artifact_metas` so that we can pass through transitive dependencies
                artifact_metas[dep] = Dict(
                    "paths" => String[],
                    "dep_uuids" => dep_dep_uuids,
                )
                continue
            end
            meta = copy(meta)

            # NOTE: We are here assuming that each dependency should download only a single
            # artifact with a specific name (e.g. `Zlib_jll` should download the `Zlib`
            # artifact).  This is currently how JLLs work, but it may not always be the case!
            # We need to come up with some way of allowing the user to specify _which_ artifacts
            # they want downloaded!
            ensure_artifact_installed(dep.name[1:end-4], meta, artifacts_toml)

            # Save the artifact path here and now (as stated above, we may eventually
            # support more than one artifact per JLL, which is why this is a vector)
            meta["paths"] = [
                Pkg.Artifacts.artifact_path(Base.SHA1(meta["git-tree-sha1"]))
            ]

            # Also save our JLL dependencies, so we can sort these later
            meta["dep_uuids"] = dep_dep_uuids
            artifact_metas[dep] = meta
        end
    end; end; end; end

    return artifact_metas
end
function collect_artifact_metas(pkg_names::Vector{<:AbstractString}; kwargs...)
    return collect_artifact_metas(
        [PackageSpec(; name) for name in pkg_names];
        kwargs...
    )
end

function pkg_dep_match(pkg, dep)
    if pkg.uuid !== nothing && dep.uuid !== nothing
        return pkg.uuid == dep.uuid
    end
    return pkg.name == dep.name
end

"""
    collect_artifact_paths(dependencies::Vector;
                           platform = HostPlatform(),
                           verbose = false)

A convenience wrapper around `collect_artifact_metas()` that will peel the
`meta` objects, walk the dependency tree, and return a dictionary mapping
each package in `dependencies` to a flattened vector of artifact path
directories.  Use `flatten_artifact_paths()` to further flatten the tree
into just a single vector.
"""
function collect_artifact_paths(dependencies::Vector{PackageSpec}; kwargs...)
    meta_mappings = collect_artifact_metas(dependencies; kwargs...)

    function collect_dep_paths(pkg::PackageSpec, paths::Vector{String})
        # First, the direct artifact paths:
        append!(paths, meta_mappings[pkg]["paths"])

        # Next, recurse on the dependencies
        for dep_uuid in meta_mappings[pkg]["dep_uuids"]
            pkg = only([pkg for (pkg, _) in meta_mappings if Base.UUID(pkg.uuid) == dep_uuid])
            collect_dep_paths(pkg, paths)
        end
        return paths
    end

    # Collect all dependencies for each top-level `dep`, including transitive dependencies
    collected_paths = Dict{PkgSpec,Vector{String}}()
    for dep in dependencies
        # Find corresponding key in `meta_mappings`
        pkgs = [pkg for (pkg, _) in meta_mappings if pkg_dep_match(pkg, dep)]
        if isempty(pkgs)
            @warn("Unable to find installed artifact for $(dep.name)")
            continue
        end
        pkg = only(pkgs)
        collected_paths[pkg] = collect_dep_paths(pkg, String[])
    end
    return collected_paths
end
function collect_artifact_paths(pkg_names::Vector{<:AbstractString}; kwargs...)
    return collect_artifact_paths(
        [PackageSpec(; name) for name in pkg_names];
        kwargs...
    )
end

# Helper function for throwing away the `PkgSpec` information
function flatten_artifact_paths(d::Dict{PkgSpec, Vector{String}})
    return unique(vcat(values(d)...))
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

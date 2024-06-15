using Pkg, HistoricalStdlibVersions
using Base: UUID

# Pkg.PackageSpec return different types in different Julia versions so...
const PkgSpec = typeof(Pkg.PackageSpec(name="dummy"))
const VersionSpec = Pkg.Types.VersionSpec

# If we don't have `stdlib_version` from Pkg, recreate it ourselves
if !isdefined(Pkg.Types, :stdlib_version)
    function stdlib_version(uuid::Base.UUID, julia_version::Union{VersionNumber,Nothing})::Union{VersionNumber,Nothing}
        last_stdlibs = Pkg.Types.get_last_stdlibs(julia_version)
        if !(uuid in keys(last_stdlibs))
            return nothing
        end
        return last_stdlibs[uuid][2]
    end
else
    const stdlib_version = Pkg.Types.stdlib_version
end

if isdefined(Pkg, :Registry) && isdefined(Pkg.Registry, :registry_info)
    const registry_info = Pkg.Registry.registry_info
elseif isdefined(Pkg, :RegistryHandling) && isdefined(Pkg.RegistryHandling, :registry_info)
    const registry_info = Pkg.RegistryHandling.registry_info
end

if isdefined(Pkg, :respect_sysimage_versions)
    function with_no_pkg_handrails(f::Function)
        old_respect_sysimage_versions = Pkg.RESPECT_SYSIMAGE_VERSIONS[]
        Pkg.respect_sysimage_versions(false)
        try
            return f()
        finally
            Pkg.respect_sysimage_versions(old_respect_sysimage_versions)
        end
    end
else
    function with_no_pkg_handrails(f::Function)
        return f()
    end
end

if isdefined(Pkg, :should_autoprecompile)
    function with_no_auto_precompilation(f::Function)
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "false") do
            return f()
        end
    end
else
    function with_no_auto_precompilation(f::Function)
        return f()
    end
end

"""
    collect_jll_uuids(manifest::Pkg.Types.Manifest, dependencies::Set{UUID})

Return a `Set` of all JLL packages in the `manifest` with `dependencies` being
the list of direct dependencies of the environment.
"""
function collect_jll_uuids(manifest::Pkg.Types.Manifest, dependencies::Set{UUID})
    jlls = copy(dependencies)
    for (uuid, pkg_entry) in manifest
        if uuid in jlls
            for (dep_name, dep_uuid) in pkg_entry.deps
                if endswith(dep_name, "_jll")
                    push!(jlls, dep_uuid)
                end
            end
        end
    end
    if jlls == dependencies
        return jlls
    else
        return collect_jll_uuids(manifest, jlls)
    end
end

"""
    get_addable_spec(name::AbstractString, version::VersionNumber)

Given a JLL name and registered version, return a `PackageSpec` that, when passed as a
`Dependency`, ensures that exactly that version will be installed.
"""
function get_addable_spec(name::AbstractString, version::VersionNumber;
                          ctx = Pkg.Types.Context(), verbose::Bool = false)
    # First, resolve the UUID
    uuid = first(Pkg.Types.registry_resolve!(ctx.registries, Pkg.Types.PackageSpec(;name))).uuid

    # Ensure that all fields of `version` are present, e.g. if there's no build number insert one:
    if isempty(version.build)
        version = VersionNumber(
            version.major,
            version.minor,
            version.patch,
            (),
            (UInt64(0),),
        )
    end

    # Next, determine the tree hash from the registry
    repo_urls = Set{String}()
    tree_hashes = Set{Base.SHA1}()
    for reg in ctx.registries
        if !haskey(reg, uuid)
            continue
        end

        pkg_info = registry_info(reg[uuid])
        if pkg_info.repo !== nothing
            push!(repo_urls, pkg_info.repo)
        end
        if pkg_info.version_info !== nothing
            if haskey(pkg_info.version_info, version)
                version_info = pkg_info.version_info[version]
                push!(tree_hashes, version_info.git_tree_sha1)
            end
        end
    end

    if isempty(tree_hashes)
        @error("Unable to find dependency!",
            name,
            version,
            registries=ctx.registries,
        )
        error("Unable to find dependency!")
    end
    if length(tree_hashes) != 1
        @error("Multiple treehashes found!",
            name,
            version,
            tree_hashes,
            registries=ctx.registries,
        )
        error("Multiple treehashes found!")
    end

    tree_hash_sha1 = first(tree_hashes)

    # Once we have a tree hash, turn that into a git commit sha
    git_commit_sha = nothing
    valid_url = nothing
    for url in repo_urls
        git_commit_sha = get_commit_sha(url, tree_hash_sha1; verbose)
        # Stop searching urls as soon as we find one
        if git_commit_sha !== nothing
            valid_url = url
            break
        end
    end

    if git_commit_sha === nothing
        @error("Unable to find revision for specified dependency!",
            name,
            version,
            tree_hash = bytes2hex(tree_hash_sha1.bytes),
            repo_urls,
        )
        error("Unable to find revision for specified dependency!")
    end

    return Pkg.Types.PackageSpec(
        name=name,
        uuid=uuid,
        #version=version,
        tree_hash=tree_hash_sha1,
        repo=Pkg.Types.GitRepo(rev=git_commit_sha, source=valid_url),
    )
end

# We only want to update the registry of each depot once per run
const _updated_depots = Set{String}()
function update_registry(outs = stdout)
    if Pkg.depots1() ∉ _updated_depots
        Pkg.Registry.download_default_registries(outs)
        Pkg.Registry.update(
            [Pkg.RegistrySpec(uuid = "23338594-aafe-5451-b93e-139f81909106")];
            io=outs,
        )
        push!(_updated_depots, Pkg.depots1())
    end
end

function update_pkg_historical_stdlibs()
    # If we're using v1.x, we need to manually install these.
    if !isdefined(HistoricalStdlibVersions, :register!)
        append!(empty!(Pkg.Types.STDLIBS_BY_VERSION), HistoricalStdlibVersions.STDLIBS_BY_VERSION)
        merge!(empty!(Pkg.Types.UNREGISTERED_STDLIBS), HistoricalStdlibVersions.UNREGISTERED_STDLIBS)
    end
    return nothing
end

# Helper function to move our primary depot to a new location
function with_depot_path(f::Function, new_path::String)
    new_depot_path = [
        abspath(new_path),
        abspath(Sys.BINDIR, "..", "local", "share", "julia"),
        abspath(Sys.BINDIR, "..", "share", "julia"),
    ]
    old_depot_path = copy(Base.DEPOT_PATH)
    try
        empty!(Base.DEPOT_PATH)
        append!(Base.DEPOT_PATH, new_depot_path)
        f()
    finally
        empty!(Base.DEPOT_PATH)
        append!(Base.DEPOT_PATH, old_depot_path)
    end
end

using Pkg
using Base: UUID

# Pkg.PackageSpec return different types in different Julia versions so...
const PkgSpec = typeof(Pkg.PackageSpec(name="dummy"))

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
`Dependency`, ensures that exactly that version will be installed.  Example usage:

    dependencies = [
        BuildDependency(get_addable_spec("LLVM_jll", v"9.0.1+0")),
    ]
"""
function get_addable_spec(name::AbstractString, version::VersionNumber;
                          ctx = Pkg.Types.Context(), verbose::Bool = false)
    # First, resolve the UUID
    uuid = first(Pkg.Types.registry_resolve!(ctx.registries, Pkg.Types.PackageSpec(;name))).uuid

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

# We only want to update the registry once per run
registry_updated = false
function update_registry(outs = stdout, )
    global registry_updated
    if !registry_updated
        Pkg.Registry.update(
            [Pkg.RegistrySpec(uuid = "23338594-aafe-5451-b93e-139f81909106")];
            io=outs,
        )
        registry_updated = true
    end
end

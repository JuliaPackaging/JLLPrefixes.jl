using LibGit2, LibGit2_jll, SHA, Scratch, Preferences

"""
    cached_git_clone(url::String); desired_commit = nothing, verbose = false)

Return the path to a local git clone of the given `url`.  If `desired_commit` is given,
then a cached git repository will not be updated if the commit already exists locally.
"""
function cached_git_clone(url::String;
                          desired_commit::Union{Nothing, String} = nothing,
                          clones_dir::String = @load_preference("clone_dir", @get_scratch!("git_clones")),
                          verbose::Bool = false)
    repo_path = joinpath(clones_dir, string(basename(url), "-", bytes2hex(sha256(url))))
    if isdir(repo_path)
        if verbose
            @info("Using cached git repository", url, repo_path)
        end
        # If we didn't just mercilessly obliterate the cached git repo, use it!
        LibGit2.with(LibGit2.GitRepo(repo_path)) do repo
            # In some cases, we know the hash we're looking for, so only fetch() if
            # this git repository doesn't contain the hash we're seeking.
            # this is not only faster, it avoids race conditions when we have
            # multiple builders on the same machine all fetching at once.
            if desired_commit === nothing || !LibGit2.iscommit(desired_commit, repo)
                LibGit2.fetch(repo)
            end
        end
    else
        if verbose
            @info("Cloning git repository", url, repo_path)
        end
        # If there is no repo_path yet, clone it down into a bare repository
        LibGit2.clone(url, repo_path; isbare=true)
    end
    return repo_path
end

"""
    get_tree_hash(tree::LibGit2.GitTree)

Given a `GitTree`, get the `GitHash` that identifies it.
"""
function get_tree_hash(tree::LibGit2.GitTree)
    oid_ptr = Ref(LibGit2.GitHash())
    oid_ptr = ccall((:git_tree_id, libgit2), Ptr{LibGit2.GitHash}, (Ptr{Cvoid},), tree.ptr)
    oid_ptr == C_NULL && throw(ArgumentError("bad tree ID: $tree"))
    return unsafe_load(oid_ptr)
end

"""
    get_commit_sha(url::String, tree_hash::Base.SHA1; verbose::Bool=false)

Find the latest git commit corresponding to the given git tree SHA1 for the remote
repository with the given `url`.  The repository is cached locally for quicker future
access.  If `verbose` is `true`, print to screen some debugging information.
The return value is the commit SHA as a `String`, if the corresponding revision is found,
`nothing` otherwise.
"""
function get_commit_sha(url::String, tree_hash::Base.SHA1; verbose::Bool=false)
    git_commit_sha = nothing
    dir = cached_git_clone(url; verbose)

    LibGit2.with(LibGit2.GitRepo(dir)) do repo
        LibGit2.with(LibGit2.GitRevWalker(repo)) do walker
            # The repo is cached, so locally it may be checking out an outdated commit.
            # Start the search from HEAD of the tracking upstream repo.
            try
                LibGit2.push!(walker, LibGit2.GitHash(LibGit2.peel(LibGit2.GitCommit, LibGit2.upstream(LibGit2.head(repo)))))
            catch
                @warn("Could not walk from origin branch!")
                LibGit2.push_head!(walker)
            end
            # For each commit in the git repo, check to see if its treehash
            # matches the one we're looking for.
            for oid in walker
                tree = LibGit2.peel(LibGit2.GitTree, LibGit2.GitCommit(repo, oid))
                if all(get_tree_hash(tree).val .== tree_hash.bytes)
                    git_commit_sha = LibGit2.string(oid)
                    break
                end
            end
        end
    end
    return git_commit_sha
end

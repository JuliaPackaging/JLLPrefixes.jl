using Git, SHA, Scratch, Preferences

iscommit(repo::String, commit::String) = success(git(["-C", repo, "cat-file", "-e", commit]))

"""
    cached_git_clone(url::String; desired_commit = nothing, verbose = false)

Return the path to a local git clone of the given `url`.  If `desired_commit` is given,
then a cached git repository will not be updated if the commit already exists locally.
"""
function cached_git_clone(url::String;
                          desired_commit::Union{Nothing,String} = nothing,
                          clones_dir::String = @load_preference("clone_dir", @get_scratch!("git_clones")),
                          verbose::Bool = false)
    repo_path = joinpath(clones_dir, string(basename(url), "-", bytes2hex(sha256(url))))
    if isdir(repo_path)
        if verbose
            @info("Using cached git repository", url, repo_path)
        end
        
        # If we didn't just mercilessly obliterate the cached git repo, use it!
        # In some cases, we know the hash we're looking for, so only fetch() if
        # this git repository doesn't contain the hash we're seeking.
        # this is not only faster, it avoids race conditions when we have
        # multiple builders on the same machine all fetching at once.
        if desired_commit === nothing || iscommit(repo_path, desired_commit)
            run(git(["-C", repo_path, "fetch"]))
        end
    else
        if verbose
            @info("Cloning git repository", url, repo_path)
        end
        # If there is no repo_path yet, clone it down into a bare repository
        run(git(["clone", "--bare", url, repo_path]))
    end
    return repo_path
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
    repo_path = cached_git_clone(url; verbose)

    tree_hash_str = bytes2hex(tree_hash.bytes)
    commit_hash_str = nothing
    open(git(["-C", repo_path, "log", "--all", "--pretty=format:%T %H"])) do io
        for line in readlines(io)
            if startswith(line, tree_hash_str)
                commit_hash_str = split(line, " ")[2]
                break
            end
        end
    end
    return commit_hash_str
end

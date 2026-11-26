using Git, SHA, Scratch, Preferences

git_clone_path(url::String, clones_dir::String = get_git_clones_dir()) =
    joinpath(clones_dir, string(basename(url), "-", bytes2hex(sha256(url))))

iscommit(repo::String, commit::String) = success(git(["-C", repo, "cat-file", "-e", commit]))

"""
    cached_git_clone(url::String; desired_commit = nothing, verbose = false)

Return the path to a local git clone of the given `url`.  If `desired_commit` is given,
then a cached git repository will not be updated if the commit already exists locally.
"""
function cached_git_clone(url::String;
                          desired_commit::Union{Nothing,String} = nothing,
                          clones_dir::String = get_git_clones_dir(),
                          verbose::Bool = false)
    quiet_args = String[]
    if !verbose
        push!(quiet_args, "-q")
    end

    repo_path = git_clone_path(url, clones_dir)
    if isfile(joinpath(repo_path, "HEAD"))
        if verbose
            @info("Using cached git repository", url, repo_path)
        end
        
        # If we didn't just mercilessly obliterate the cached git repo, use it!
        # In some cases, we know the hash we're looking for, so only fetch() if
        # this git repository doesn't contain the hash we're seeking.
        # this is not only faster, it avoids race conditions when we have
        # multiple builders on the same machine all fetching at once.
        if desired_commit === nothing || !iscommit(repo_path, desired_commit)
            run(git(["-C", repo_path, "fetch", quiet_args...]))
            run(git(["-C", repo_path, "reset", "FETCH_HEAD", "--soft", quiet_args...]))
        end
    else
        if isdir(repo_path)
            rm(repo_path; recursive=true, force=true)
        end
        if verbose
            @info("Cloning git repository", url, repo_path)
        end
        # If there is no repo_path yet, clone it down into a bare repository
        run(git(["clone", "--bare", url, repo_path, quiet_args...]))
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
    # Search an existing clone first, and only fetch if it lacks `tree_hash`
    repo_path = git_clone_path(url)
    if isfile(joinpath(repo_path, "HEAD"))
        commit_hash_str = find_commit_with_tree(repo_path, tree_hash)
        if commit_hash_str !== nothing
            return commit_hash_str
        end
    end
    return find_commit_with_tree(cached_git_clone(url; verbose), tree_hash)
end

function find_commit_with_tree(repo_path::String, tree_hash::Base.SHA1)
    tree_hash_str = bytes2hex(tree_hash.bytes)
    open(git(["-C", repo_path, "log", "--all", "--pretty=format:%T %H"])) do io
        for line in readlines(io)
            if startswith(line, tree_hash_str)
                return String(split(line, " ")[2])
            end
        end
        return nothing
    end
end

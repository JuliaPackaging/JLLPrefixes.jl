using Test, JLLPrefixes, Base.BinaryPlatforms, Pkg, Preferences
using JLLPrefixes: PkgSpec, flatten_artifact_paths

const verbose = false
const linux64 = Platform("x86_64", "linux")
const linux64_to_linux64 = Platform("x86_64", "linux"; target_arch="x86_64", target_os="linux", target_libc="glibc")

# On windows, we run into `$GIT_DIR too big` errors a lot if our git clones
# are nested too deeply, as they default to, when using scratchspaces.
# So here we just set them to be stored in a much shorter dirname:
if Sys.iswindows()
    JLLPrefixes.set_git_clones_dir!(mktempdir())
end
pkg_depot = mktempdir()

@testset "JLL collection" begin
    function check_zstd_jll(zstd_pkgspec, zstd_artifacts)
        # Ensure this pkgspec is named Zstd_jll
        @test zstd_pkgspec.name == "Zstd_jll"

        # It only had one artifact to download, and it exists
        @test length(zstd_artifacts) == 1
        @test isdir(zstd_artifacts[1])
        @test isfile(joinpath(zstd_artifacts[1], "include", "zstd.h"))
    end

    @testset "Zstd_jll (native)" begin
        # Start with a simple JLL with no dependencies
        artifact_paths = collect_artifact_paths(["Zstd_jll"]; pkg_depot, verbose)

        # There was only one JLL downloaded, and it was Zstd_jll
        @test length(artifact_paths) == 1
        zstd_pkgspec, zstd_artifacts = first(artifact_paths)
        check_zstd_jll(zstd_pkgspec, zstd_artifacts)
    end

    # Do another simple JLL installation, but this time for a few different architectures
    for platform in [Platform("aarch64", "linux"), Platform("x86_64", "macos"), Platform("i686", "windows")]
        @testset "Zstd_jll ($(platform))" begin
            artifact_paths = collect_artifact_paths(["Zstd_jll"]; platform, pkg_depot, verbose)
            check_zstd_jll(first(artifact_paths)...)

            # Ensure that `platform` is not mutated
            @test !haskey(tags(platform), "sanitize")

            # Test that we're getting the kind of dynamic library we expect
            artifact_dir = first(first(values(artifact_paths)))
            if os(platform) == "windows"
                libdir = "bin"
                libname = "libzstd-1.dll"
            elseif os(platform) == "macos"
                libdir = "lib"
                libname = "libzstd.1.dylib"
            else
                libdir = "lib"
                libname = "libzstd.so.1"
            end
            @test isfile(joinpath(artifact_dir, libdir, libname))
        end
    end

    # Test that we can request a particular version of Zstd_jll
    @testset "Zstd_jll ($(linux64), v1.4.2+0)" begin
        artifact_paths = collect_artifact_paths([PkgSpec(;name="Zstd_jll", version=v"1.4.2+0")]; platform=linux64, pkg_depot, verbose)

        # There was only one JLL downloaded, and it was Zstd_jll
        @test length(artifact_paths) == 1
        zstd_pkgspec, zstd_artifacts = first(artifact_paths)
        check_zstd_jll(zstd_pkgspec, zstd_artifacts)

        # Ensure that this is actually version 1.4.2
        artifact_dir = first(first(values(artifact_paths)))
        @test isfile(joinpath(artifact_dir, "lib", "libzstd.so.1.4.2"))
    end

    # Kick it up a notch; start involving dependencies
    @testset "XML2_jll ($(linux64), v2.9.12+0, dependencies)" begin
        # Lock XML2_jll to v2.9 in case it adds more dependencies in the future
        artifact_paths = collect_artifact_paths(
            [PkgSpec(;name="XML2_jll", version=v"2.9.12+0")];
            platform=linux64,
            pkg_depot,
            verbose,
        )

        @test length(artifact_paths) == 1
        @test sort([p.name for p in keys(artifact_paths)]) == ["XML2_jll"]
        @test length(only(values(artifact_paths))) == 3
    end

    @testset "Honor existant JLL versions" begin
        mktempdir() do project_dir
            # First, we install a specific Zlib_jll into our environment, an
            # old version that will not be selected by a future `Pkg.add()`
            artifact_paths = collect_artifact_paths(
                [PkgSpec(;name="Zlib_jll", version=v"1.2.11+3")];
                platform=linux64,
                project_dir,
                pkg_depot,
                verbose,
            )
            zlib_path = only(only(values(artifact_paths)))

            # Next, we ensure that this exact same zlib is used when installing `XML2_jll` here:
            artifact_paths = collect_artifact_paths(
                [PkgSpec(;name="XML2_jll", version=v"2.9.12+0")];
                platform=linux64,
                project_dir,
                pkg_depot,
                verbose,
            )
            @test zlib_path ∈ only(values(artifact_paths))
        end

        # Next, test that the Project.toml is actually untouched if all dependencies already
        # exist within a given project.
        mktempdir() do project_dir
            # Install XML2_jll
            collect_artifact_paths([PkgSpec(;name="XML2_jll")]; platform=linux64, project_dir, pkg_depot)

            project_path = joinpath(project_dir, "Project.toml")
            project_content = read(project_path)
            cp(project_path, string(project_path, ".orig"))

            manifest_path = joinpath(project_dir, "Manifest.toml")
            manifest_content = read(manifest_path)
            cp(manifest_path, string(manifest_path, ".orig"))

            function ensure_unchanged(;show::Bool = true)
                project_new_content = read(project_path)
                if project_new_content != project_content
                    if show
                        @warn("Showing Project.toml diff")
                        run(ignorestatus(`diff $(project_path).orig $(project_path)`))
                    end
                    return false
                end

                manifest_new_content = read(manifest_path)
                if manifest_new_content != manifest_content
                    if show
                        @warn("Showing Manifest.toml diff")
                        run(ignorestatus(`diff $(manifest_path).orig $(manifest_path)`))
                    end
                    return false
                end

                # Reset so future runs don't get clobbered
                cp(string(project_path, ".orig"), project_path; force=true)
                cp(string(manifest_path, ".orig"), manifest_path; force=true)

                return true
            end

            artifact_paths = collect_artifact_paths(
                [PkgSpec(;name="XML2_jll")];
                platform=linux64,
                project_dir,
                pkg_depot,
                verbose,
            )
            @test ensure_unchanged()

            artifact_paths = collect_artifact_paths(
                [PkgSpec(;name="Zlib_jll")];
                platform=linux64,
                project_dir,
                pkg_depot,
                verbose,
            )
            @test ensure_unchanged()

            # Purposefully install an old version
            artifact_paths = collect_artifact_paths(
                [PkgSpec(;name="Zlib_jll", version=v"1.2.12+0",)];
                platform=linux64,
                project_dir,
                pkg_depot,
                verbose,
            )
            @test !ensure_unchanged()
        end
    end

    # Install two packages that have nothing to do with eachother at the same time
    @testset "Bzip2_jll + Zstd_jll" begin
        artifact_paths = collect_artifact_paths(["Bzip2_jll", "Zstd_jll"]; pkg_depot, verbose)
        @test length(artifact_paths) == 2
        @test sort([p.name for p in keys(artifact_paths)]) == ["Bzip2_jll", "Zstd_jll"]
    end

    # Test stdlibs across versions.  Note that `GMP_jll` was _not_ a standard library in v1.5,
    # it _is_ a standard library in v1.6 and v1.7.
    GMP_JULIA_VERSIONS = [
        ("10.3.2", v"1.5"),
        ("10.4.0", v"1.6"),
        ("10.4.1", v"1.7"),
    ]
    for (GMP_soversion, julia_version) in GMP_JULIA_VERSIONS
        @testset "GMP_jll (Julia $(julia_version))" begin
            artifact_paths = collect_artifact_paths(["GMP_jll"]; platform=Platform("x86_64", "linux"; julia_version), pkg_depot, verbose)
            @test length(artifact_paths) == 1
            gmp_artifact_dir = only(first(values(artifact_paths)))
            @test isfile(joinpath(gmp_artifact_dir, "lib", "libgmp.so.$(GMP_soversion)"))
        end
    end

    #=
    # NOTE: Now that I'm using `get_addable_spec()` to convert all stdlib packages
    # to being installed via `repo/rev`, this test seems to work just fine.

    # Test "impossible" situations via `julia_version == nothing`
    @testset "Impossible Constraints" begin
        # We can't naively install OpenBLAS v0.3.13 and LBT v5.1.1, because those are
        # from conflicting Julia versions, and the Pkg resolver doesn't like that
        for julia_version in (v"1.7.3", v"1.8.0")
            @test_throws Pkg.Resolve.ResolverError collect_artifact_paths([
                PkgSpec(;name="OpenBLAS_jll",  version=v"0.3.13"),
                PkgSpec(;name="libblastrampoline_jll", version=v"5.1.1"),
            ]; platform=Platform("x86_64", "linux"; julia_version), pkg_depot, verbose)
        end

        # So we must pass julia_version == nothing, as is the case in our `linux64` object
        artifact_paths = collect_artifact_paths([
            PkgSpec(;name="OpenBLAS_jll",  version=v"0.3.13"),
            PkgSpec(;name="libblastrampoline_jll", version=v"5.1.1"),
        ]; platform=linux64, pkg_depot, verbose)
        @test length(flatten_artifact_paths(artifact_paths)) == 3
        @test sort([p.name for p in keys(artifact_paths)]) == ["OpenBLAS_jll", "libblastrampoline_jll"]
    end
    =#

    # Test adding something that doesn't exist on a certain platform
    @testset "Platform Incompatibility" begin
        @test_logs (:warn, r"Dependency Libuuid_jll does not have a mapping for artifact Libuuid for platform") begin
            # This test _must_ be verbose, so we catch the appropriate logs
            artifact_paths = collect_artifact_paths(["Libuuid_jll"]; platform=Platform("x86_64", "macos"), pkg_depot, verbose=true)
            @test only(keys(artifact_paths)).name == "Libuuid_jll"
            @test isempty(flatten_artifact_paths(artifact_paths))
        end
    end

    @testset "Transitive dependency deduplication" begin
        # Test that when we collect two JLLs that share a transitive dependency, it gets
        # deduplicated when flattened:
        artifact_paths = collect_artifact_paths([
            "libass_jll",
            "wget_jll",
            "Zlib_jll"
        ]; platform=linux64, pkg_depot, verbose)
        # Get the Zlib_jll artifact name:
        zlib_artifact_path = only(only([paths for (pkg, paths) in artifact_paths if pkg.name == "Zlib_jll"]))

        # The `Zlib_jll` artifact is counted in every package:
        for (pkg, paths) in artifact_paths
            @test zlib_artifact_path ∈ paths
        end

        # When we flatten the artifact paths, we deduplicate:
        flattened = flatten_artifact_paths(artifact_paths)
        @test zlib_artifact_path ∈ flattened
        @test length(flattened) == length(unique(flattened))
    end

    @testset "Shared dependency resolution" begin
        special_autoconf_pkgspec = PkgSpec(;
            name="autoconf_jll",
            repo=Pkg.Types.GitRepo(
                rev="c726a3f9a56a11c1dbd6d2352a7fe6219e38405a",
                source="https://github.com/staticfloat/autoconf_jll.jl",
            ),
        )

        autoconf_path = only(flatten_artifact_paths(collect_artifact_paths([special_autoconf_pkgspec]; platform=linux64, pkg_depot, verbose)))

        # Test that if we have a special version of a JLL, it gets resolved as a dependency of another JLL:
        artifact_paths = collect_artifact_paths([
            special_autoconf_pkgspec,
            PkgSpec(;name="automake_jll"),
        ]; platform=linux64, pkg_depot, verbose=true)

        for (pkg, paths) in artifact_paths
            @test autoconf_path ∈ paths
        end
    end
end

exe = ""
if Sys.iswindows()
    exe = ".exe"
end

@testset "FFMPEG installation test" begin
    installer_strategies = [:copy, :hardlink, :symlink, :auto]
    mktempdir() do depot
        for strategy in installer_strategies
            mktempdir() do prefix
                artifact_paths = collect_artifact_paths(["FFMPEG_jll"]; pkg_depot=depot, verbose)
                @testset "$strategy strategy" begin
                    deploy_artifact_paths(prefix, artifact_paths; strategy)

                    # Ensure that a bunch of tools we expect to be installed are, in fact, installed
                    for tool in ("ffmpeg", "fc-cache", "iconv", "x264", "x265")
                        # Use `@eval` here so the test itself shows the tool name, for easier debugging
                        tool_name = string(tool, exe)
                        @eval @test ispath(joinpath($(prefix), "bin", $(tool_name)))

                        # Extra `realpath()` here to explicitly test dereferencing symlinks
                        @eval @test isfile(realpath(joinpath($(prefix), "bin", $(tool_name))))
                    end

                    # Symlinking is insufficient for RPATH, unfortunately.
                    if strategy == :symlink && !Sys.iswindows()
                        @test !success(`$(joinpath(prefix, "bin", "ffmpeg$(exe)")) -version`)
                    else
                        # Hilariously, since Windows doesn't use `RPATH` but just dumps
                        # everything into the `bin` directory, it tends to work just fine:
                        @test success(`$(joinpath(prefix, "bin", "ffmpeg$(exe)")) -version`)
                    end
                end
            end
        end
    end
end

@testset "tree_hash-provided sources" begin
    artifact_paths = collect_artifact_paths([
        PkgSpec(;
            name="Binutils_jll",
            version=v"2.38.0+4",
            #tree_hash=Base.SHA1("ffa0762c5e00e109c88f820b3e15fca842ffa808"),
        ),
    ]; platform=linux64_to_linux64, pkg_depot, verbose)

    # Test that we get precisely the right Binutils_jll version.
    # X-ref: https://github.com/JuliaBinaryWrappers/Binutils_jll.jl/blob/Binutils-v2.38.0%2B4/Artifacts.toml#L683-L690
    @test any(basename.(only([v for (k, v) in artifact_paths if k.name == "Binutils_jll"])) .== Ref("cfacb1560e678d1d058d397d4b792f0d525ce5e1"))

    # Do the same for Zlib_jll, since that's a stdlib.
    # Here, we purposefully install an old version
    artifact_paths = collect_artifact_paths([
        PkgSpec(;
            name="Zlib_jll",
            version=v"1.2.12+0",
        ),
    ]; platform=linux64_to_linux64, pkg_depot, verbose)
    # X-ref: https://github.com/JuliaBinaryWrappers/Zlib_jll.jl/blob/9f5383c83cc4ecfb070381521df24eae13fff67a/Artifacts.toml#L110-L114
    @test any(basename.(only([v for (k, v) in artifact_paths if k.name == "Zlib_jll"])) .== Ref("53e6c375d00db870bf575afc992c03c54cba1d7e"))
end

@testset "repo-provided sources" begin
    artifact_paths = collect_artifact_paths([
        PkgSpec(;
            name="Binutils_jll",
            repo=Pkg.Types.GitRepo(
                rev="89943b0c48834fb291b24fb73d90b821185ed44b",
                source="https://github.com/JuliaBinaryWrappers/Binutils_jll.jl"
            ),
        ),
    ]; platform=linux64_to_linux64, pkg_depot, verbose)
    @test any(basename.(only([v for (k, v) in artifact_paths if k.name == "Binutils_jll"])) .== "cfacb1560e678d1d058d397d4b792f0d525ce5e1")
end

using JLLPrefixes: get_git_clones_dir, set_git_clones_dir!, cached_git_clone
@testset "set_git_clones_dir!" begin
    mktempdir() do clones_dir
        old_clones_dir = get_git_clones_dir()
        try
            set_git_clones_dir!(clones_dir)
            @test get_git_clones_dir() == clones_dir

            path = cached_git_clone("https://github.com/JuliaBinaryWrappers/CompilerSupportLibraries_jll.jl")
            @test startswith(path, clones_dir)
        finally
            set_git_clones_dir!(old_clones_dir)
        end
        @test get_git_clones_dir() == old_clones_dir
    end
end
